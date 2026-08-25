module Mimic
  module LlmConfig
    class Sampling
      FLAGS = {
        "temperature" => "temp",
        "top_p" => "top-p",
        "top_k" => "top-k",
        "min_p" => "min-p",
        "presence_penalty" => "presence-penalty",
        "repeat_penalty" => "repeat-penalty",
      }.freeze
      KEYS = FLAGS.keys.freeze

      # llama-server's own defaults, so a key nothing overrides describes the
      # same behaviour as passing no flag at all.
      DEFAULTS = {
        "temperature" => 0.8,
        "top_p" => 0.95,
        "top_k" => 40,
        "min_p" => 0.05,
        "presence_penalty" => 0.0,
        "repeat_penalty" => 1.0,
      }.freeze

      # The publisher's own suggestion, carried in the GGUF header. Only
      # these three are ever written there -- min_p and the two penalties
      # appear in no GGUF and stay at the default.
      HEADER_KEYS = {
        "general.sampling.temp" => "temperature",
        "general.sampling.top_p" => "top_p",
        "general.sampling.top_k" => "top_k",
      }.freeze

      # GGUF stores these as float32, so a published 0.95 reads back as
      # 0.949999988079071 and would reach the engine that way.
      FLOAT_PRECISION = 6

      def self.resolve(metadata)
        suggested = HEADER_KEYS.filter_map do |header_key, key|
          value = metadata[header_key]
          [key, value.is_a?(Float) ? value.round(FLOAT_PRECISION) : value] unless value.nil?
        end
        DEFAULTS.merge(suggested.to_h)
      end

      def initialize(model_cfg)
        @cfg = model_cfg
      end

      def to_h = FLAGS.to_h { |key, flag| [flag, @cfg[key]] }
      def to_args = to_h.flat_map { |flag, value| ["--#{flag}", value.to_s] }
    end
  end
end
