require 'fluent/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent
  class PrometheusOutputMonitorInput < Input
    Plugin.register_input('prometheus_output_monitor', self)

    config_param :interval, :time, :default => 5
    attr_reader :registry

    MONITOR_IVARS = [
      :num_errors,
      :emit_count,

      # for v0.12
      :last_retry_time,

      # from v0.14
      :emit_records,
      :write_count,
      :rollback_count,
    ]

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      hostname = Socket.gethostname
      expander = Fluent::Prometheus.placeholder_expander(log)
      placeholders = expander.prepare_placeholders({'hostname' => hostname})
      @base_labels = Fluent::Prometheus.parse_labels_elements(conf)
      @base_labels.each do |key, value|
        @base_labels[key] = expander.expand(value, placeholders)
      end

      if defined?(Fluent::Plugin) && defined?(Fluent::Plugin::MonitorAgentInput)
        # from v0.14.6
        @monitor_agent = Fluent::Plugin::MonitorAgentInput.new
      else
        @monitor_agent = Fluent::MonitorAgentInput.new
      end

      @metrics = {
        buffer_queue_length: @registry.gauge(
          :fluentd_output_status_buffer_queue_length,
          'Current buffer queue length.'),
        buffer_total_queued_size: @registry.gauge(
          :fluentd_output_status_buffer_total_bytes,
          'Current total size of queued buffers.'),
        retry_counts: @registry.gauge(
          :fluentd_output_status_retry_count,
          'Current retry counts.'),
        num_errors: @registry.gauge(
          :fluentd_output_status_num_errors,
          'Current number of errors.'),
        emit_count: @registry.gauge(
          :fluentd_output_status_emit_count,
          'Current emit counts.'),
        emit_records: @registry.gauge(
          :fluentd_output_status_emit_records,
          'Current emit records.'),
        write_count: @registry.gauge(
          :fluentd_output_status_write_count,
          'Current write counts.'),
        rollback_count: @registry.gauge(
          :fluentd_output_status_rollback_count,
          'Current rollback counts.'),
        retry_wait: @registry.gauge(
          :fluentd_output_status_retry_wait,
          'Current retry wait'),
      }
    end

    class TimerWatcher < Coolio::TimerWatcher
      def initialize(interval, repeat, log, &callback)
        @callback = callback
        @log = log
        super(interval, repeat)
      end

      def on_timer
        @callback.call
      rescue
        @log.error $!.to_s
        @log.error_backtrace
      end
    end

    def start
      super
      @loop = Coolio::Loop.new
      @timer = TimerWatcher.new(@interval, true, log, &method(:update_monitor_info))
      @loop.attach(@timer)
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      super
      @loop.watchers.each {|w| w.detach }
      @loop.stop
      @thread.join
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def update_monitor_info
      opts = {
        ivars: MONITOR_IVARS,
        with_retry: true,
      }

      agent_info = @monitor_agent.plugins_info_all(opts).select {|info|
        info['plugin_category'] == 'output'.freeze
      }

      monitor_info = {
        'buffer_queue_length' => @metrics[:buffer_queue_length],
        'buffer_total_queued_size' => @metrics[:buffer_total_queued_size],
        'retry_count' => @metrics[:retry_counts],
      }
      instance_vars_info = {
        num_errors: @metrics[:num_errors],
        write_count: @metrics[:write_count],
        emit_count: @metrics[:emit_count],
        emit_records: @metrics[:emit_records],
        rollback_count: @metrics[:rollback_count],
      }

      agent_info.each do |info|
        label = labels(info)

        monitor_info.each do |name, metric|
          if info[name]
            metric.set(label, info[name])
          end
        end

        if info['instance_variables']
          instance_vars_info.each do |name, metric|
            if info['instance_variables'][name]
              metric.set(label, info['instance_variables'][name])
            end
          end
        end

        # compute current retry_wait
        if info['retry']
          next_time = info['retry']['next_time']
          start_time = info['retry']['start']
          if start_time.nil? && info['instance_variables']
            # v0.12 does not include start, use last_retry_time instead
            start_time = info['instance_variables'][:last_retry_time]
          end

          wait = 0
          if next_time && start_time
            wait = next_time - start_time
          end
          @metrics[:retry_wait].set(label, wait.to_f)
        end
      end
    end

    def labels(plugin_info)
      @base_labels.merge(
        plugin_id: plugin_info["plugin_id"],
        type: plugin_info["type"],
      )
    end
  end
end
