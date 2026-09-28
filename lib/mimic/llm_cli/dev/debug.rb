require_relative "../../ui"
require_relative "../base"
require_relative "../../engine_cli"
require_relative "../../engine/server_process"
require_relative "../../llm_config"
require_relative "../../model/library"

module Mimic
  module LlmCli
    module Dev
      class Debug < Base
        CONTEXT = 60_000

        desc "switch", "start one engine, stop it, then start the other"
        method_option :from, type: :string, default: "llama.cpp", desc: "engine to start first"
        method_option :to, type: :string, default: "ik_llama.cpp", desc: "engine to start second"
        def switch
          config = LlmConfig.load
          plans = [options[:from], options[:to]].map { |name| [name, model_for(config, name)] }
          return unless plans.all? { |name, model| model || missing_model(name) }

          puts "host=#{config.llama.host} port=#{config.llama.port} context=#{CONTEXT}"
          stop_server

          plans.each { |name, model| return unless run_engine(config, name, model) }
          puts Ui.green("\nboth engines served the port")
        ensure
          Engine::ServerProcess.chat.stop(exclude: Engine::ServerProcess.embed.pids)
          EngineCli::Registry.for(LlmConfig.load).render_preset
        end

        private

        def run_engine(config, name, model)
          config.llama.engine = name
          config.model.path = model.path.to_s
          config.model.context_length = CONTEXT
          engine = EngineCli::Registry.for(config)
          puts "\n== #{name} · #{model.path.basename(".gguf")} =="
          return missing_binary(name) if engine.find_binary.nil?

          result = nil
          elapsed = timed { result = engine.start(remember: false) }
          puts result.ok? ? Ui.green(result.message) : Ui.red(result.message)
          puts "started in #{elapsed}s"
          return false unless result.ok?

          stop_server
          true
        end

        def model_for(config, engine_name)
          config.llama.engine = engine_name
          models = Model::Library.new(config).chat
          configured = Pathname.new(config.model.path.to_s).expand_path
          models.find { |model| model.path.expand_path == configured } || models.min_by { |model| model.path.size }
        end

        def missing_model(name)
          puts Ui.red("no chat model compatible with #{name}")
          false
        end

        def missing_binary(name)
          puts Ui.red("no #{name} llama-server built -- run `llm engines update`")
          false
        end

        def stop_server
          stopped = Engine::ServerProcess.chat.stop(exclude: Engine::ServerProcess.embed.pids)
          puts "llama-server: #{stopped ? 'stopped' : 'was not running'}"
        end

        def timed
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          yield
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
        end
      end
    end
  end
end
