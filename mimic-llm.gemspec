require_relative "lib/mimic/version"

Gem::Specification.new do |spec|
  spec.name          = "mimic-llm"
  spec.version       = Mimic::VERSION
  spec.authors       = ["raykin"]
  spec.summary       = "Local LLM stack on llama.cpp: llm (engine) + mimic (agents), Linux only"
  spec.description   = "Two CLIs over a local llama.cpp stack. `llm` sets up and runs the " \
                       "inference server: it picks a GGUF, sizes the context against the card's " \
                       "real VRAM -- sliding-window, recurrent and MTP draft caches included -- " \
                       "builds llama.cpp or ik_llama.cpp when no server is on PATH, and pushes " \
                       "the active model into whatever agent configs already exist. `mimic` " \
                       "launches Claude Code or Codex against that server through their own " \
                       "documented provider settings, each in an isolated config dir, so a " \
                       "local model answers instead of a hosted one. Linux only, and it " \
                       "downloads no models."
  spec.license       = "MIT"
  spec.homepage      = "https://github.com/raykin/mimic-llm"
  spec.metadata      = {
    "source_code_uri" => "https://github.com/raykin/mimic-llm",
    "bug_tracker_uri" => "https://github.com/raykin/mimic-llm/issues",
    "changelog_uri" => "https://github.com/raykin/mimic-llm/commits/main",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.2"
  # lib/**/* rather than lib/**/*.rb: agent/codex_fallback_prompt.md is read
  # at runtime, and a .rb-only glob leaves it out of the built gem.
  #
  # llm_cli/dev holds the development-only command (`llm debug`). It drives
  # local engine integration checks that ship nowhere, so an installed gem must
  # not advertise it; llm_cli/root.rb registers it only when this directory is
  # present.
  spec.files         = (Dir["lib/**/*", "exe/*"] - Dir["lib/mimic/llm_cli/dev/**/*"])
                       .select { |f| File.file?(f) } +
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
