require_relative "fmt"
require_relative "probes"
require_relative "services/llama"

module Mimic
  # What `llm status` reports: the config profile, corrected by whatever the
  # running instance was actually started with.
  class ServerStatus
    def initialize(config, pastel:)
      @config = config
      @pastel = pastel
    end

    def print
      running = Services::Llama.new(@config).running?
      running ? print_running : print_stopped

      ctx, kv, n_slots = running ? live_profile : config_profile
      model_path = @config.model_path
      puts "Model:    #{model_path.empty? ? '<unset>' : File.basename(model_path)}"
      puts "Context:  #{Fmt.commas(ctx)} tokens#{slot_split(ctx, n_slots)}"
      puts "KV cache: #{kv}"
      puts "Binary:   #{@config.binary}"
    end

    private

    def config_profile = [@config.context_length, @config.cache_type, @config.n_slots]

    def live_profile
      ctx, kv, n_slots = config_profile
      argv = live_instance_args
      unless argv
        puts @pastel.yellow("  (couldn't confirm live ctx/slots from server -- showing config.yaml, may be stale)")
        return [ctx, kv, n_slots]
      end

      [(arg_value(argv, "--ctx-size") || ctx).to_i,
       arg_value(argv, "--cache-type-k") || kv,
       (arg_value(argv, "--parallel") || n_slots).to_i]
    end

    def print_running
      pid = Services::Llama::PID_FILE.exist? ? Services::Llama::PID_FILE.read.strip : "?"
      puts "#{@pastel.green('Engine:')} #{@config.engine}"
      puts "#{@pastel.green('Status:')} running at #{@config.base_url} (pid #{pid})"
    end

    def print_stopped
      puts "#{@pastel.yellow('Engine:')} #{@config.engine}"
      puts "#{@pastel.yellow('Status:')} not running"
    end

    def slot_split(ctx, n_slots)
      return "" unless n_slots > 1

      "  (#{n_slots} x #{Fmt.commas(n_slots.positive? ? ctx / n_slots : ctx)})"
    end

    # argv of the actually-running llama-server instance, straight from the
    # router's own /v1/models -- config.yaml can be stale (e.g. `llm
    # benchmark` overrides ctx/slots without persisting them).
    def live_instance_args
      data = Probes.http_json("#{@config.base_url}/v1/models")
      return nil if data.nil?

      entry = (data["data"] || []).find { |e| e["id"] == @config.model_alias && e.dig("status", "value") == "loaded" }
      entry&.dig("status", "args")
    end

    def arg_value(argv, flag)
      idx = argv.index(flag)
      idx ? argv[idx + 1] : nil
    end
  end
end
