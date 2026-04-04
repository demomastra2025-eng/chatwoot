class Captain::PromptRenderer
  class << self
    def render(template_name, context = {})
      Captain::PromptRegistry.render!(template_name, variables: context)
    end
  end
end
