class Captain::Tools::Copilot::UpdateLabelService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_label'
  end

  description 'Update an existing account label'
  param :label_id, type: :integer, desc: 'Label ID', required: true
  param :title, type: :string, desc: 'Updated label title', required: false
  param :description, type: :string, desc: 'Updated description', required: false
  param :color, type: :string, desc: 'Updated hex color', required: false
  param :show_on_sidebar, type: :boolean, desc: 'Updated sidebar visibility', required: false

  def execute(label_id:, title: nil, description: nil, color: nil, show_on_sidebar: nil)
    label = account.labels.find(label_id)
    update_attributes = {}
    update_attributes[:title] = title.to_s.strip.downcase unless title.nil?
    update_attributes[:description] = description.to_s.strip.presence unless description.nil?
    update_attributes[:color] = color.to_s.strip.presence unless color.nil?
    update_attributes[:show_on_sidebar] = cast_boolean(show_on_sidebar) unless show_on_sidebar.nil?
    label.update!(update_attributes)

    formatted_payload(action: 'update_label', label: label_payload(label.reload))
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
