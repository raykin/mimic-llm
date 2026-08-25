require_relative "lib/mimic/version"

Gem::Specification.new do |spec|
  spec.name          = "mimic-llm"
  spec.version       = Mimic::VERSION
  spec.authors       = ["raykin"]
  spec.summary       = "Local LLM stack on llama.cpp: llm (engine) + mimic (agents), Linux only"
  spec.required_ruby_version = ">= 3.2"
  spec.files         = Dir["lib/**/*.rb", "exe/*"]
  spec.bindir        = "exe"
  spec.executables   = ["mimic", "llm"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.4"
  spec.add_dependency "cli-ui", "~> 2.7"
  # cli-ui's prompt requires reline/readline, which stopped being default gems
  # in Ruby 4.0 -- without this the whole prompt layer fails to load.
  spec.add_dependency "reline", "~> 0.6"

  spec.add_development_dependency "rspec", "~> 3.13"
end
