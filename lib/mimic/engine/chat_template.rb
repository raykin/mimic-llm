require "pathname"
require_relative "../paths"
require_relative "../model/schema"
require_relative "../model"
require_relative "../util/probes"

module Mimic
  # A model's embedded Jinja chat template, and the override mimic hands the
  # server when that template would throw on real agent traffic.
  #
  # The Qwen-family templates ship `raise_exception` guards that llama.cpp's
  # minja evaluates at render time: a request whose message list trips one
  # comes back as a 500 rather than a completion. Claude Code trips
  # `System message must be at the beginning` because llama.cpp's
  # /v1/messages bridge emits system content the guard does not expect.
  #
  # Each rule replaces one guard with what the template should have rendered.
  # `requires` names the constructs the replacement leans on -- a template
  # that phrases its loop differently gets refused rather than rewritten
  # wrong, and the hand-written override in CHAT_TEMPLATES_DIR stays the
  # answer for it.
  module Engine
    class ChatTemplate
      METADATA_KEY = "tokenizer.chat_template".freeze
      RAISE_CALL = /\{\{-?\s*raise_exception\(\s*(['"])(.*?)\1\s*\)\s*-?\}\}/m

      NOOP = "{{- '' }}".freeze

      Rule = Struct.new(:match, :replacement, :requires, keyword_init: true)

      RULES = [
        Rule.new(
          match: /system message must be at the beginning/i,
          replacement: %q({{- '<|im_start|>system\n' + content + '<|im_end|>' + '\n' }}),
          requires: ["<|im_start|>system", "set content = render_content("],
        ),
        Rule.new(
          match: /unexpected message role/i,
          replacement: %q({{- '<|im_start|>user\n' + content + '<|im_end|>' + '\n' }}),
          requires: ["<|im_start|>system", "set content = render_content("],
        ),
        Rule.new(
          match: /unexpected item type in content/i,
          replacement: "{{- item.text if item.text is defined else '' }}",
          requires: ["for item in content"],
        ),
        Rule.new(
          match: /unexpected content type/i,
          replacement: "{{- content | string }}",
          requires: [],
        ),
        Rule.new(
          match: /system message cannot contain|no messages provided|no user query found/i,
          replacement: NOOP,
          requires: [],
        ),
      ].freeze

      # Renders the message shapes real agents send through the server's own
      # /apply-template, which runs the same minja pass as a completion. A 500
      # here is the template throwing -- the exact failure a request would hit,
      # measured instead of predicted. Both engines expose the endpoint.
      class Probe
        SYSTEM = { role: "system", content: "You are a coding agent." }.freeze
        USER = { role: "user", content: "list the files" }.freeze

        FIXTURES = {
          "a system message after the first turn" =>
            [SYSTEM, USER, { role: "system", content: "<system-reminder>stay on task</system-reminder>" }],
          "an assistant tool call and its response" =>
            [SYSTEM, USER,
             { role: "assistant", content: "",
               tool_calls: [{ type: "function",
                              function: { name: "Read", arguments: { path: "/tmp/x" } } }] },
             { role: "tool", content: "file body" }],
          "content sent as typed blocks" =>
            [SYSTEM, { role: "user", content: [{ type: "text", text: "and now?" }] }],
        }.freeze

        def initialize(base_url, model_alias:)
          @url = "#{base_url}/apply-template"
          @model_alias = model_alias
        end

        def failures
          FIXTURES.filter_map do |label, messages|
            res = Util::Probes.post(@url, { model: @model_alias, messages: messages })
            label if res && res.code.to_i >= 500
          end
        end
      end

      def initialize(model_path, model_alias:)
        @model_path = model_path.to_s
        @model_alias = model_alias.to_s
      end

      def source
        return @source if defined?(@source)

        # full: the template is written after the vocab arrays, and the
        # default read stops at the first of them.
        @source = Model::Header.new(@model_path).metadata(full: true)[METADATA_KEY]
      rescue StandardError
        @source = nil
      end

      def guarded? = source.to_s.include?("raise_exception")

      # The rewritten template, or nil when a guard has no rule or a rule's
      # replacement would not fit this template.
      def sanitized
        return nil unless guarded?

        refused = false
        rewritten = source.gsub(RAISE_CALL) do
          rule = rule_for(Regexp.last_match(2))
          next (refused = true) && "" if rule.nil?

          rule.replacement
        end
        refused ? nil : rewritten
      end

      # Hand-written first: a file the user wrote is a decision, and mimic's
      # rules do not get to overrule it.
      def override_path
        [hand_written, generated].find(&:file?)
      end

      def install
        return nil if hand_written.file?

        text = sanitized
        return nil if text.nil?

        generated.dirname.mkpath
        generated.write(text.end_with?("\n") ? text : "#{text}\n")
        generated
      end

      private

      def hand_written = Paths::CHAT_TEMPLATES_DIR / "#{@model_alias}.jinja"
      def generated = Paths::GENERATED_TEMPLATES_DIR / "#{@model_alias}.jinja"

      def rule_for(message)
        rule = RULES.find { |r| r.match.match?(message) }
        return nil if rule.nil?
        return nil unless rule.requires.all? { |needle| source.include?(needle) }

        rule
      end
    end
  end
end
