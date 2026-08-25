# A Qwen-family chat template reduced to the one guard that matters: a
# system message anywhere but first raises instead of rendering.
GUARDED_TEMPLATE = <<~JINJA.freeze
  {%- for message in messages %}
      {%- set content = render_content(message.content, true)|trim %}
      {%- if message.role == "system" %}
          {%- if not loop.first %}
              {{- raise_exception('System message must be at the beginning.') }}
          {%- endif %}
      {%- else %}
          {{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}
      {%- endif %}
  {%- endfor %}
JINJA
