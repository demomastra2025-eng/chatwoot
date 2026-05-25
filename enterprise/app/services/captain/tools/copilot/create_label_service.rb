class Captain::Tools::Copilot::CreateLabelService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_label'
  end

  description 'Create a new account label'
  param :title, type: :string, desc: 'Label title', required: true
  param :description, type: :string, desc: 'Optional label description', required: false
  param :color, type: :string, desc: 'Optional hex color', required: false
  param :show_on_sidebar, type: :boolean, desc: 'Whether to show the label in the sidebar', required: false

  def execute(title:, description: nil, color: nil, show_on_sidebar: nil)
    ensure_account_administrator!

    label = account.labels.create!(
      title: title.to_s.strip.downcase,
      description: description.to_s.strip.presence,
      color: color.to_s.strip.presence,
      show_on_sidebar: show_on_sidebar.nil? ? nil : cast_boolean(show_on_sidebar)
    )

    formatted_payload(action: 'create_label', label: label_payload(label))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def label_payload(label)
    {
      id: label.id,
      title: label.title,
      description: label.description,
      color: label.color,
      show_on_sidebar: label.show_on_sidebar,
      created_at: label.created_at&.iso8601,
      updated_at: label.updated_at&.iso8601
    }
  end
end
