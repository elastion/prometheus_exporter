# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/client'
require 'prometheus_exporter/instrumentation'

class PrometheusCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
    PrometheusExporter::Metric::Base.default_aggregation = nil
  end

  def teardown
    PrometheusExporter::Metric::Base.default_aggregation = nil
  end

  class PipedClient
    def initialize(collector, custom_labels: nil)
      @collector = collector
      @custom_labels = custom_labels
    end

    def send_json(obj)
      payload = obj.merge(custom_labels: @custom_labels).to_json
      @collector.process(payload)
    end
  end

  def test_local_metric
    collector = PrometheusExporter::Server::Collector.new
    client = PrometheusExporter::LocalClient.new(collector: collector)

    PrometheusExporter::Instrumentation::Process.start(client: client, labels: { hello: "custom label" })

    metrics_text = ""
    TestHelper.wait_for(2) do
      metrics_text = collector.prometheus_metrics_text
      metrics_text != ""
    end

    PrometheusExporter::Instrumentation::Process.stop

    assert_match(/heap_live_slots/, metrics_text)
    assert_match(/hello.*custom label/, metrics_text)
  end

  def test_register_metric
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new("amazing", "amount of amazing")
    collector.register_metric(metric)
    metric.observe(77)
    metric.observe(2, red: "alert")
    text = <<~TXT
      # HELP amazing amount of amazing
      # TYPE amazing gauge
      amazing 77
      amazing{red="alert"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_increment_gauge_when_specified
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      prometheus_exporter_action: :increment,
      value: 1
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{key1="test1"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_decrement_gauge_when_specified
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      prometheus_exporter_action: :decrement,
      value: 5
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{key1="test1"} -10
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_export_summary_stats
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :summary,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      value: 0.6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name summary
      test_name{key1=\"test1\",quantile=\"0.99\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.9\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.5\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.1\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.01\"} 0.6
      test_name_sum{key1=\"test1\"} 1.2
      test_name_count{key1=\"test1\"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_pass_options_to_summary
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :summary,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      opts: { quantiles: [0.75, 0.5, 0.25] },
      value: 8
    }
    collector.process(json.to_json)

    %w[3 3 5 8 1 7 9 1 2 6 4 0 2 8 3 6 4 2 4 5 4 8 9 1 4 7 3 6 1 5 6 4].each do |num|
      json[:value] = num.to_i
      collector.process(json.to_json)
    end

    # In this case our 0 to 10 based data is skewed a bit low
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name summary
      test_name{key1=\"test1\",quantile=\"0.75\"} 6.0
      test_name{key1=\"test1\",quantile=\"0.5\"} 4.0
      test_name{key1=\"test1\",quantile=\"0.25\"} 3.0
      test_name_sum{key1=\"test1\"} 149.0
      test_name_count{key1=\"test1\"} 33
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_export_histogram_stats
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :histogram,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      value: 6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name histogram
      test_name_bucket{key1=\"test1\",le=\"+Inf\"} 2
      test_name_bucket{key1=\"test1\",le=\"10.0\"} 2
      test_name_bucket{key1=\"test1\",le=\"5.0\"} 0
      test_name_bucket{key1=\"test1\",le=\"2.5\"} 0
      test_name_bucket{key1=\"test1\",le=\"1\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.5\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.25\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.1\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.05\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.025\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.01\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.005\"} 0
      test_name_count{key1=\"test1\"} 2
      test_name_sum{key1=\"test1\"} 12.0
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_pass_options_to_histogram
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :histogram,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      opts: { buckets: [5, 6, 7] },
      value: 6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name histogram
      test_name_bucket{key1=\"test1\",le=\"+Inf\"} 2
      test_name_bucket{key1=\"test1\",le=\"7\"} 2
      test_name_bucket{key1=\"test1\",le=\"6\"} 2
      test_name_bucket{key1=\"test1\",le=\"5\"} 0
      test_name_count{key1=\"test1\"} 2
      test_name_sum{key1=\"test1\"} 12.0
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_collect_sidekiq_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("sidekiq_failed_jobs_total{job_name=\"FalseClass\",queue=\"default\"} 1"), "has failed job")

    assert(result.include?("sidekiq_jobs_total{job_name=\"String\",queue=\"default\"} 1"), "has working job")
    assert(result.include?("sidekiq_job_duration_seconds"), "has duration")
  end

  def test_it_can_collect_sidekiq_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    active_job_worker = {}
    active_job_worker.stub(:class, "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper") do
      instrument.call(active_job_worker, { 'wrapped' => 'WrappedClass' }, "default") do
        # nothing
      end
    end

    delayed_worker = {}
    delayed_worker.stub(:class, "Sidekiq::Extensions::DelayedClass") do
      instrument.call(delayed_worker, { 'args' => [ "---\n- !ruby/class 'String'\n- :foo\n- -" ] }, "default") do
        # nothing
      end
    end

    delayed_worker.stub(:class, "Sidekiq::Extensions::DelayedModel") do
      instrument.call(delayed_worker, { 'args' => [ "---\n- !ruby/object {}\n- :foo\n- -" ] }, "default") do
        # nothing
      end
    end

    delayed_worker.stub(:class, "Sidekiq::Extensions::DelayedClass") do
      instrument.call(delayed_worker, { 'args' => [ 1 ] }, "default") do
        # nothing
      end
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('sidekiq_failed_jobs_total{job_name="FalseClass",queue="default",service="service1"} 1'), "has failed job")
    assert(result.include?('sidekiq_jobs_total{job_name="String",queue="default",service="service1"} 1'), "has working job")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",queue="default",service="service1",quantile="0.99"}'), "has duration quantile 0.99")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",queue="default",service="service1",quantile="0.9"}'), "has duration quantile 0.9")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",queue="default",service="service1",quantile="0.5"}'), "has duration quantile 0.5")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",queue="default",service="service1",quantile="0.1"}'), "has duration quantile 0.1")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",queue="default",service="service1",quantile="0.01"}'), "has duration quantile 0.01")
    assert(result.include?('sidekiq_jobs_total{job_name="WrappedClass",queue="default",service="service1"} 1'), "has sidekiq working job from ActiveJob")
    assert(result.include?('sidekiq_jobs_total{job_name="String#foo",queue="default",service="service1"} 1'), "has sidekiq delayed class")
    assert(result.include?('sidekiq_jobs_total{job_name="Object#foo",queue="default",service="service1"} 1'), "has sidekiq delayed class")
    assert(result.include?('sidekiq_jobs_total{job_name="Sidekiq::Extensions::DelayedClass",queue="default",service="service1"} 1'), "has sidekiq delayed class")
  end

  def test_it_can_collect_sidekiq_queue_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })
    instrument = PrometheusExporter::Instrumentation::SidekiqQueue.new

    mocks_for_sidekiq_que_all = 2.times.map do |i|
      mock = Minitest::Mock.new
      mock.expect(
        :name,
        "que_#{i}",
      )
      mock.expect(
        :size,
        10 + i,
      )
      mock.expect(
        :latency,
        1.to_f + i,
      )
      mock.expect(
        :name,
        "que_#{i}",
      )
    end

    mock_sidekiq_que = Minitest::Mock.new
    mock_sidekiq_que.expect(
      :all,
      mocks_for_sidekiq_que_all,
    )

    Object.stub_const(:Sidekiq, Module) do
      ::Sidekiq.stub_const(:Queue, mock_sidekiq_que) do
        instrument.stub(:collect_current_process_queues, ["que_0", "que_1"]) do
          metric = instrument.collect
          client.send_json metric
        end
      end
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('sidekiq_queue_backlog{queue="que_0",service="service1"} 10'), "has number of backlog")
    assert(result.include?('sidekiq_queue_backlog{queue="que_1",service="service1"} 11'), "has number of backlog")
    assert(result.include?('sidekiq_queue_latency_seconds{queue="que_0",service="service1"} 1'), "has latency")
    assert(result.include?('sidekiq_queue_latency_seconds{queue="que_1",service="service1"} 2'), "has latency")
    mocks_for_sidekiq_que_all.each { |m| m.verify }
    mock_sidekiq_que.verify
  end

  def test_it_can_collect_sidekiq_metrics_in_histogram_mode
    PrometheusExporter::Metric::Base.default_aggregation = PrometheusExporter::Metric::Histogram
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert_includes(result, "sidekiq_job_duration_seconds histogram")
  end

  def test_it_can_collect_shoryuken_metrics_with_custom_lables
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::Shoryuken.new(client: client)

    instrument.call("hello", nil, "default", "body") do
    end
    begin
      instrument.call(false, nil, "default", "body") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("shoryuken_failed_jobs_total{job_name=\"FalseClass\",queue_name=\"\",service=\"service1\"} 1"), "has failed job")
    assert(result.include?("shoryuken_jobs_total{job_name=\"String\",queue_name=\"\",service=\"service1\"} 1"), "has working job")
    assert(result.include?("shoryuken_job_duration_seconds{job_name=\"String\",queue_name=\"\",service=\"service1\"} "), "has duration")
  end

  def test_it_merges_custom_labels_for_generic_metrics
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      custom_labels: { host: "example.com" },
      keys: { key1: 'test1' },
      value: 5
    }.to_json

    collector.process(json)

    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{host="example.com",key1="test1"} 5
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_collect_process_metrics
    # make some mini racer data
    ctx = MiniRacer::Context.new
    ctx.eval("1")

    collector = PrometheusExporter::Server::Collector.new

    process_instrumentation = PrometheusExporter::Instrumentation::Process.new(type: "web")
    collected = process_instrumentation.collect

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    v8_str = "v8_heap_count{type=\"web\",pid=\"#{collected[:pid]}\"} #{collected[:v8_heap_count]}"

    assert(text.include?(v8_str), "must include v8 metric")
    assert(text.include?("minor_gc_ops_total"), "must include counters")
  end

  def test_it_can_collect_delayed_job_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")
    job.expect(:queue, "my_queue")
    job.expect(:attempts, 0)

    instrument.call(job, 20, 10, 0, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:queue, "my_queue")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, 10, 0, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("delayed_failed_jobs_total{queue_name=\"my_queue\",job_name=\"Object\"} 1"), "has failed job")
    assert(result.include?("delayed_jobs_total{queue_name=\"my_queue\",job_name=\"Class\"} 1"), "has working job")
    assert(result.include?("delayed_job_duration_seconds{queue_name=\"my_queue\",job_name=\"Class\"}"), "has duration")
    assert(result.include?("delayed_jobs_enqueued{queue_name=\"my_queue\"} 10"), "has enqueued count")
    assert(result.include?("delayed_jobs_pending{queue_name=\"my_queue\"} 0"), "has pending count")
    job.verify
    failed_job.verify
  end

  def test_it_can_collect_delayed_job_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")
    job.expect(:queue, "my_queue")
    job.expect(:attempts, 0)

    instrument.call(job, 25, 10, 0, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:queue, "my_queue")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, 10, 0, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('delayed_failed_jobs_total{queue_name="my_queue",service="service1",job_name="Object"} 1'), "has failed job")
    assert(result.include?('delayed_jobs_total{queue_name="my_queue",service="service1",job_name="Class"} 1'), "has working job")
    assert(result.include?('delayed_job_duration_seconds{queue_name="my_queue",service="service1",job_name="Class"}'), "has duration")
    assert(result.include?('delayed_jobs_enqueued{queue_name="my_queue",service="service1"} 10'), "has enqueued count")
    assert(result.include?('delayed_jobs_pending{queue_name="my_queue",service="service1"} 0'), "has pending count")
    job.verify
    failed_job.verify
  end

  def test_it_can_collect_delayed_job_metrics_in_histogram_mode
    PrometheusExporter::Metric::Base.default_aggregation = PrometheusExporter::Metric::Histogram
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")
    job.expect(:queue, "my_queue")
    job.expect(:attempts, 0)

    instrument.call(job, 20, 10, 0, nil, "default") do
      # nothing
    end

    result = collector.prometheus_metrics_text

    assert_includes(result, "delayed_job_duration_seconds_summary histogram")
    assert_includes(result, "delayed_job_attempts_summary histogram")
    job.verify
  end

  require 'minitest/stub_const'

  def test_it_can_collect_puma_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    mock_puma = Minitest::Mock.new
    mock_puma.expect(
      :stats,
      '{ "workers": 1, "phase": 0, "booted_workers": 1, "old_workers": 0, "worker_status": [{ "pid": 87819, "index": 0, "phase": 0, "booted": true, "last_checkin": "2018-10-16T11:50:31Z", "last_status": { "backlog":0, "running":8, "pool_capacity":32, "max_threads": 32 } }] }'
    )

    instrument = PrometheusExporter::Instrumentation::Puma.new

    Object.stub_const(:Puma, mock_puma) do
      metric = instrument.collect
      client.send_json metric
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('puma_booted_workers{phase="0",service="service1"} 1'), "has booted workers")
    assert(result.include?('puma_request_backlog{phase="0",service="service1"} 0'), "has total backlog")
    assert(result.include?('puma_thread_pool_capacity{phase="0",service="service1"} 32'), "has pool capacity")
    mock_puma.verify
  end

  def test_it_can_collect_puma_metrics_with_metric_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    mock_puma = Minitest::Mock.new
    mock_puma.expect(
      :stats,
      '{ "workers": 1, "phase": 0, "booted_workers": 1, "old_workers": 0, "worker_status": [{ "pid": 87819, "index": 0, "phase": 0, "booted": true, "last_checkin": "2018-10-16T11:50:31Z", "last_status": { "backlog":0, "running":8, "pool_capacity":32, "max_threads": 32 } }] }'
    )

    instrument = PrometheusExporter::Instrumentation::Puma.new({ foo: 'bar' })

    Object.stub_const(:Puma, mock_puma) do
      metric = instrument.collect
      client.send_json metric
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('puma_booted_workers{phase="0",service="service1",foo="bar"} 1'), "has booted workers")
    assert(result.include?('puma_request_backlog{phase="0",service="service1",foo="bar"} 0'), "has total backlog")
    assert(result.include?('puma_thread_pool_capacity{phase="0",service="service1",foo="bar"} 32'), "has pool capacity")
    mock_puma.verify
  end

  def test_it_can_collect_resque_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    mock_resque = Minitest::Mock.new
    mock_resque.expect(
      :info,
      { processed: 12, failed: 2, pending: 42, queues: 2, workers: 1, working: 1 }
    )

    instrument = PrometheusExporter::Instrumentation::Resque.new

    Object.stub_const(:Resque, mock_resque) do
      metric = instrument.collect
      client.send_json metric
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('resque_processed_jobs{service="service1"} 12'), "has processed jobs")
    assert(result.include?('resque_failed_jobs{service="service1"} 2'), "has failed jobs")
    assert(result.include?('resque_pending_jobs{service="service1"} 42'), "has pending jobs")
    mock_resque.verify
  end

  def test_it_can_collect_unicorn_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    mock_unicorn_listener_address_stats = Minitest::Mock.new
    mock_unicorn_listener_address_stats.expect(:active, 2)
    mock_unicorn_listener_address_stats.expect(:queued, 10)

    instrument = PrometheusExporter::Instrumentation::Unicorn.new(
      pid_file: "/tmp/foo.pid",
      listener_address: "localhost:22222",
    )

    instrument.stub(:worker_process_count, 4) do
      instrument.stub(:listener_address_stats, mock_unicorn_listener_address_stats) do
        metric = instrument.collect
        client.send_json metric
      end
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('unicorn_workers{service="service1"} 4'), "has the number of workers")
    assert(result.include?('unicorn_active_workers{service="service1"} 2'), "has number of active workers")
    assert(result.include?('unicorn_request_backlog{service="service1"} 10'), "has number of request baklogs")
    mock_unicorn_listener_address_stats.verify
  end
end
