# frozen_string_literal: true

class Whatsapp::TemplateLanguageResolver
  LANGUAGE_SUFFIX_PATTERN = /_(?:[a-z]{2}(?:_[a-z]{2})?)\z/i

  def initialize(reminder:, template_params:, conversation: nil)
    @reminder = reminder
    @template_params = (template_params || {}).deep_stringify_keys
    @conversation = conversation
  end

  def call
    return @template_params if @template_params['name'].blank? || account&.bilingual_templates_enabled?

    approved_templates = available_approved_templates
    return @template_params if approved_templates.empty?

    resolve_candidate_template(approved_templates) || @template_params
  end

  def render_switched_body(resolved_params)
    return nil if resolved_params.blank?

    resolved = resolved_params.deep_stringify_keys
    return nil unless template_switched?(resolved)
    return nil unless approved_template_exists?(resolved['name'], resolved['language'])

    render_template_body(resolved, strict_language: true)
  end

  def render_template_body(resolved_params, strict_language: false)
    return nil if resolved_params.blank?

    Whatsapp::TemplateMessageRenderer.new(
      channel: inbox&.channel,
      template_params: resolved_params,
      strict_language: strict_language
    ).render_text
  end

  private

  def resolve_candidate_template(approved_templates)
    expected_body_count = expected_body_param_count(approved_templates)
    candidate_languages.each do |target_lang|
      matched = find_matching_template(approved_templates, target_lang, expected_body_count)
      next unless matched

      return @template_params.merge(
        'name' => matched['name'],
        'language' => matched['language'],
        'category' => matched['category'].presence || @template_params['category']
      ).compact
    end

    nil
  end

  def template_switched?(resolved)
    orig_name = @template_params['name'].to_s
    orig_lang = Whatsapp::SupportedLanguages.normalize_code(@template_params['language'])
    new_name = resolved['name'].to_s
    new_lang = Whatsapp::SupportedLanguages.normalize_code(resolved['language'])

    new_name.present? && (!new_name.casecmp?(orig_name) || new_lang != orig_lang)
  end

  def approved_template_exists?(name, language)
    normalized_lang = Whatsapp::SupportedLanguages.normalize_code(language)
    available_approved_templates.any? do |tpl|
      tpl['name'].to_s.casecmp?(name.to_s) &&
        Whatsapp::SupportedLanguages.normalize_code(tpl['language']) == normalized_lang
    end
  end

  def account
    @reminder.account
  end

  def inbox
    @reminder.target_inbox || @conversation&.inbox || @reminder.conversation&.inbox
  end

  def contact
    @reminder.target_contact ||
      @reminder.remindable.try(:patient_contact) ||
      @reminder.remindable.try(:contact) ||
      @conversation&.contact ||
      @reminder.conversation&.contact
  end

  def candidate_languages
    [
      contact&.preferred_client_language,
      account&.primary_client_language,
      @template_params['language']
    ].filter_map { |lang| Whatsapp::SupportedLanguages.normalize_code(lang) }.uniq
  end

  def available_approved_templates
    channel = inbox&.channel
    return [] unless channel.respond_to?(:message_templates)

    Array(channel.message_templates).filter_map do |tpl|
      normalized = tpl.is_a?(Hash) ? tpl.deep_stringify_keys : nil
      normalized if normalized && normalized['status'].to_s.upcase == 'APPROVED'
    end
  end

  def expected_body_param_count(approved_templates)
    processed_body = @template_params.dig('processed_params', 'body')
    return processed_body.size if processed_body.is_a?(Hash) || processed_body.is_a?(Array)

    configured = approved_templates.find do |tpl|
      tpl['name'].to_s.casecmp?(@template_params['name'].to_s) &&
        Whatsapp::SupportedLanguages.normalize_code(tpl['language']) ==
          Whatsapp::SupportedLanguages.normalize_code(@template_params['language'])
    end
    configured ? template_body_param_count(configured) : nil
  end

  def template_body_param_count(template)
    body_comp = Array(template['components']).find { |c| c.to_h['type'].to_s.upcase == 'BODY' }
    text = body_comp.to_h['text'].to_s
    text.scan(/\{\{\s*(\d+)\s*\}\}/).flatten.uniq.size
  end

  def find_matching_template(approved_templates, target_lang, expected_body_count)
    configured_name = @template_params['name'].to_s
    base_name = configured_name.sub(LANGUAGE_SUFFIX_PATTERN, '')
    candidate_names = [
      "#{base_name}_#{target_lang.downcase}",
      configured_name,
      base_name
    ].uniq

    candidate_names.each do |candidate_name|
      matched = approved_templates.find do |tpl|
        tpl['name'].to_s.casecmp?(candidate_name) &&
          Whatsapp::SupportedLanguages.normalize_code(tpl['language']) == target_lang &&
          (expected_body_count.nil? || template_body_param_count(tpl) == expected_body_count)
      end
      return matched if matched
    end

    nil
  end
end
