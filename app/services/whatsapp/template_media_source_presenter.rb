class Whatsapp::TemplateMediaSourcePresenter
  pattr_initialize [:whatsapp_channel!]

  def perform
    templates = Array(whatsapp_channel.message_templates).deep_dup
    return templates unless templates.any? { |template| carousel_component(template).present? }

    sources = source_index
    templates.each { |template| decorate_template(template, sources) }

    templates
  end

  private

  def source_index
    whatsapp_channel.template_media_sources.with_attached_file.index_by do |source|
      [source.template_name, source.language.downcase, source.card_index]
    end
  end

  def decorate_template(template, sources)
    carousel = carousel_component(template)
    return if carousel.blank?

    supports_media_upload = whatsapp_channel.provider == 'whatsapp_cloud'
    template['one_link_carousel_media_upload_supported'] = supports_media_upload
    return unless supports_media_upload

    Array(carousel&.[]('cards')).each_with_index do |card, card_index|
      source = sources[[template['name'], template['language'].to_s.downcase, card_index]]
      decorate_card(card, source) if usable_source?(source)
    end
  end

  def carousel_component(template)
    Array(template['components']).find { |component| component['type'] == 'CAROUSEL' }
  end

  def decorate_card(card, source)
    header = Array(card['components']).find { |component| component['type'] == 'HEADER' }
    return if header.blank? || header['format'].to_s.downcase != source.media_type

    header['one_link_media'] = {
      'attached' => true,
      'file_name' => source.file.attached? ? source.file.filename.to_s : nil
    }.compact
  end

  def usable_source?(source)
    source.present? && (source.file.attached? || source.source_url.present?)
  end
end
