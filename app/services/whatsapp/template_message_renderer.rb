# frozen_string_literal: true

class Whatsapp::TemplateMessageRenderer
  PLACEHOLDER_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
  RESERVED_PARAM_KEYS = %w[body header footer buttons media carousel].freeze
  MEDIA_META_KEYS = %w[media_url media_type media_name].freeze

  def initialize(channel:, template_params:, strict_language: false)
    @channel = channel
    @template_params = normalize_hash(template_params)
    @strict_language = strict_language
  end

  def render_text
    tpl = matched_template
    return nil unless tpl

    [
      render_header_text(tpl),
      render_body_text(tpl),
      render_footer_text(tpl)
    ].filter_map(&:presence).join("\n\n").presence
  end

  def render_buttons
    buttons_comp = find_component(matched_template, 'BUTTONS')
    return [] unless buttons_comp

    Array(buttons_comp['buttons']).filter_map { |raw_btn| format_button(raw_btn) }
  end

  def matched_template
    return @matched_template if defined?(@matched_template)

    @matched_template = resolve_matched_template
  end

  private

  def resolve_matched_template
    name = @template_params['name'].to_s.strip
    return nil if name.blank? || !@channel.respond_to?(:message_templates)

    templates = normalized_templates
    target_lang = normalize_lang(@template_params['language'] || @template_params['language_code'])
    find_language_match(templates, name, target_lang) || find_fallback_name_match(templates, name, target_lang)
  end

  def find_language_match(templates, name, target_lang)
    return nil if target_lang.blank?

    find_by_name_and_lang(templates, name, target_lang, approved_only: true) ||
      find_by_name_and_lang(templates, name, target_lang, approved_only: false)
  end

  def find_fallback_name_match(templates, name, target_lang)
    return nil if @strict_language && target_lang.present?

    find_by_name_only(templates, name, approved_only: true) ||
      find_by_name_only(templates, name, approved_only: false)
  end

  def format_button(raw_btn)
    btn = normalize_hash(raw_btn)
    type = btn['type'].to_s.strip.upcase
    text = btn['text'].to_s.strip
    text = 'Copy code' if text.blank? && type == 'COPY_CODE'
    return nil if text.blank?

    {
      'type' => type.presence || 'QUICK_REPLY',
      'text' => text
    }
  end

  def normalized_templates
    Array(@channel.message_templates).filter_map do |tpl|
      tpl.is_a?(Hash) ? tpl.deep_stringify_keys : nil
    end
  end

  def find_by_name_and_lang(templates, name, target_lang, approved_only:)
    templates.find do |tpl|
      next false if approved_only && tpl['status'].to_s.upcase != 'APPROVED'

      tpl['name'].to_s.casecmp?(name) && normalize_lang(tpl['language']) == target_lang
    end
  end

  def find_by_name_only(templates, name, approved_only:)
    templates.find do |tpl|
      next false if approved_only && tpl['status'].to_s.upcase != 'APPROVED'

      tpl['name'].to_s.casecmp?(name)
    end
  end

  def normalize_lang(code)
    return '' if code.blank?

    Whatsapp::SupportedLanguages.normalize_code(code.to_s)
  end

  def find_component(template, component_type)
    return nil unless template

    Array(template['components']).find do |comp|
      comp.is_a?(Hash) && comp['type'].to_s.upcase == component_type
    end
  end

  def render_header_text(template)
    header = find_component(template, 'HEADER')
    return nil unless header && header['format'].to_s.upcase == 'TEXT'

    render_component_text(header, header_params)
  end

  def render_body_text(template)
    render_component_text(find_component(template, 'BODY'), body_params)
  end

  def render_footer_text(template)
    render_component_text(find_component(template, 'FOOTER'), footer_params)
  end

  def render_component_text(component, values_map)
    return nil unless component

    raw_text = component['text'].to_s
    return nil if raw_text.blank?

    substitute_placeholders(raw_text, values_map)
  end

  def processed_params
    @template_params['processed_params']
  end

  def header_params
    raw = processed_params
    raw.is_a?(Hash) ? extract_param_map(raw['header']) : {}
  end

  def footer_params
    raw = processed_params
    raw.is_a?(Hash) ? extract_param_map(raw['footer']) : {}
  end

  def body_params
    raw = processed_params
    return extract_param_map(raw) if raw.is_a?(Array)
    return {} unless raw.is_a?(Hash)
    return extract_param_map(raw['body']) if raw.key?('body')
    return extract_param_map(raw) unless raw.keys.intersect?(RESERVED_PARAM_KEYS)

    {}
  end

  def extract_param_map(source)
    case source
    when Array
      source.each_with_index.with_object({}) do |(val, idx), acc|
        acc[(idx + 1).to_s] = scalar_param_value(val)
      end
    when Hash
      source.each_with_object({}) do |(key, val), acc|
        next if MEDIA_META_KEYS.include?(key.to_s)

        acc[key.to_s] = scalar_param_value(val)
      end
    else
      {}
    end
  end

  def scalar_param_value(val)
    return val.to_s unless val.is_a?(Hash)

    (val['text'] || val[:text] || val['value'] || val[:value] || val['parameter'] || val[:parameter]).to_s
  end

  def substitute_placeholders(raw_text, values_map)
    return raw_text if values_map.blank?

    raw_text.gsub(PLACEHOLDER_PATTERN) do
      key = Regexp.last_match(1)
      values_map[key].presence || "{{#{key}}}"
    end
  end

  def normalize_hash(obj)
    return {} unless obj.respond_to?(:to_h)

    obj.to_h.deep_stringify_keys
  rescue StandardError
    {}
  end
end
