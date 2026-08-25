require "pathname"
require_relative "../../../model"

module Mimic
  module LlmCli
    module Dev
      module Quality
        # Turns the results log local-quality-test.rb appends into a per-model
        # engine verdict.
        #
        # The log is the only record of which engine actually served a model
        # best -- Model::Memory holds ctx and offload, but engine is a global
        # config key, so nothing carried a per-model answer before this. A
        # header line is the whole record; the tables under it repeat the same
        # run pack by pack.
        #
        #   ### <alias> - <quant> - <engine> - <ctx...> - <hits>/<cases>, <pct>%, <group> - <date>
        #
        # Fields are " - " separated, which is why the split is on the
        # separator rather than a regex over the line: a quant (UD-IQ4_NL_XL)
        # and an alias (Qwen3.6-35B-A3B) both carry bare hyphens of their own.
        class EngineSeed
          HEADER = /^###\s+(?<fields>.+)$/
          SCORE = %r{\A(?<hits>\d+)/(?<cases>\d+),\s*(?<pct>\d+)%}

          Run = Struct.new(:engine, :pct, :cases)

          def initialize(log_path)
            @log_path = Pathname.new(log_path)
          end

          # Model stem ("Qwen3.8-27B-UD-IQ4_XS") => winning engine.
          def best
            runs.each_with_object({}) do |(stem, run), winners|
              current = winners[stem]
              winners[stem] = run if current.nil? || better?(run, current)
            end.transform_values(&:engine)
          end

          # Writes the verdicts onto the models the log names, and returns how
          # many were written. A model the log is silent about keeps whatever
          # it had: an absent run is no evidence, not evidence of absence.
          def apply(models)
            winners = best
            models.count do |model|
              engine = winners[model.path.basename(".gguf").to_s]
              next false if engine.nil?

              model.memory.remember_engine(engine)
              true
            end
          end

          private

          # Percentage first, then how many cases produced it: 39/45 and
          # 130/150 both read 87%, and the shorter run is the one that got
          # there by luck.
          def better?(candidate, current)
            ([candidate.pct, candidate.cases] <=> [current.pct, current.cases]) == 1
          end

          def runs
            lines.filter_map { |line| parse(line) }
          end

          def lines
            @log_path.readlines
          rescue SystemCallError
            []
          end

          def parse(line)
            match = HEADER.match(line)
            return nil if match.nil?

            fields = match[:fields].split(" - ").map(&:strip)
            score = fields.filter_map { |field| SCORE.match(field) }.first
            return nil if score.nil? || fields.size < 3

            [fields[0, 2].join("-"), Run.new(fields[2], score[:pct].to_i, score[:cases].to_i)]
          end
        end
      end
    end
  end
end
