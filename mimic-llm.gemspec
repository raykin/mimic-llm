require_relative "lib/mimic/version"

Gem::Specification.new do |spec|
  spec.name          = "mimic-llm"
  spec.version       = Mimic::VERSION
  spec.authors       = ["raykin"]
  spec.summary       = "Local LLM stack on llama.cpp: llm (engine) + mimic (agents), Linux only"
  # TODO(review): placeholders -- confirm before the first push.
  spec.description   = "TODO: a paragraph on what llm and mimic each do, and " \
                       "the llama.cpp/ik_llama.cpp assumptions in README.md"
  spec.license       = "MIT"
  spec.homepage      = "TODO-HOMEPAGE-URL"
  spec.metadata      = {
    "source_code_uri" => "TODO-REPO-URL",
    "bug_tracker_uri" => "TODO-ISSUES-URL",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.2"
  # lib/**/* rather than lib/**/*.rb: agent/codex_fallback_prompt.md is read
  # at runtime, and a .rb-only glob leaves it out of the built gem.
  spec.files         = Dir["lib/**/*", "exe/*"].select { |f| File.file?(f) } +
                       ["LICENSE", "NOTICE", "README.md"]
  spec.bindir        = "exe"
  # lllm is llm under a name that is free when another tool already owns
  # `llm` on PATH (the python llm CLI, most often).
  spec.executables   = ["mimic", "llm", "lllm"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.4"
  spec.add_dependency "cli-ui", "~> 2.7"
  # cli-ui's prompt requires reline/readline, which stopped being default gems
  # in Ruby 4.0 -- without this the whole prompt layer fails to load.
  spec.add_dependency "reline", "~> 0.6"

  spec.add_development_dependency "rspec", "~> 3.13"
end
