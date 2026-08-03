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
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-table", "~> 0.12"
  spec.add_dependency "tty-box", "~> 0.7"
  spec.add_dependency "sqlite3", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end
