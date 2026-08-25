require "pathname"

module Mimic
  module LlmCli
    module Dev
      module Quality
        # The local-quality-test.rb script, which lives in the stack repo
        # rather than in this gem -- it drives club-3090's quality-test.sh and
        # a pair of docker sandbox images, none of which ship here.
        #
        # Hence a located path rather than a required file: the env var is the
        # answer for a checkout anywhere, and the sibling default covers the
        # layout this gem is developed in (the gem is a directory inside the
        # stack repo). Absent means the command says so and stops, rather than
        # sweeping every model against nothing.
        class Harness
          ENV_VAR = "MIMIC_QUALITY_HARNESS".freeze
          SCRIPT = "local-quality-test.rb".freeze
          LOG = "local_quality.md".freeze

          class << self
            def locate
              candidates.find { |path| path.file? }
            end

            private

            # __dir__ is lib/mimic/llm_cli/dev/quality, so five levels reach the
            # gem root and six reach the stack repo the gem is checked out into.
            def candidates
              [
                ENV[ENV_VAR],
                Pathname.new(__dir__).join("../../../../../..", SCRIPT),
                Pathname.new(Dir.pwd) / SCRIPT,
              ].compact.map { |raw| Pathname.new(raw.to_s).expand_path }
            end
          end

          def initialize(script, group: "--default")
            @script = Pathname.new(script)
            @group = group
          end

          def log_path = @script.dirname / LOG

          # The harness appends its own results block and prints its own
          # progress, so its output is the report -- nothing is captured here.
          def run(model_alias)
            system(@script.to_s, @group, chdir: @script.dirname.to_s) ||
              warn("#{SCRIPT} exited non-zero for #{model_alias}")
          end
        end
      end
    end
  end
end
