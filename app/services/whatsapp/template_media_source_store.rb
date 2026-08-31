class Whatsapp::TemplateMediaSourceStore
  pattr_initialize [:whatsapp_channel!]

  def replace!(template_config, template: nil)
    config = template_config.to_h.with_indifferent_access
    cards = Array(config[:carousel_cards])
    return [] if cards.blank?
    return [] if template && template_header_types(template) != config_header_types(cards)

    resolved_sources = cards.map.with_index { |card, index| resolve_source(card.with_indifferent_access, index) }

    persist_sources(config, resolved_sources)
  end

  def delete!(template_name)
    whatsapp_channel.template_media_sources.where(template_name: template_name.to_s).destroy_all
  end

  def source_for(template_name:, language:, card_index:)
    whatsapp_channel.template_media_sources.find_by(
      template_name: template_name.to_s,
      language: language.to_s.downcase,
      card_index: card_index
    )
  end

  private

  def template_header_types(template)
    carousel = Array(template['components']).find { |component| component['type'] == 'CAROUSEL' }
    Array(carousel&.[]('cards')).map do |card|
      header = Array(card['components']).find { |component| component['type'] == 'HEADER' }
      header&.[]('format').to_s.downcase
    end
  end

  def config_header_types(cards)
    cards.map { |card| card.to_h.with_indifferent_access[:header_type].to_s.downcase }
  end

  def persist_sources(config, resolved_sources)
    ApplicationRecord.transaction do
      sources_for(config[:name], config[:language]).destroy_all
      resolved_sources.map do |source_attributes|
        blob = source_attributes.delete(:blob)
        source = whatsapp_channel.template_media_sources.create!(
          **source_attributes,
          template_name: config[:name].to_s,
          language: config[:language].to_s.downcase
        )
        source.file.attach(blob) if blob
        source
      end
    end
  end

  def sources_for(template_name, language)
    whatsapp_channel.template_media_sources.where(
      template_name: template_name.to_s,
      language: language.to_s.downcase
    )
  end

  def resolve_source(card, card_index)
    media_type = card[:header_type].to_s.downcase
    blob_signed_id = card[:sample_media_blob_id].to_s.strip
    source_url = card[:sample_media_url].to_s.strip

    if blob_signed_id.present?
      begin
        blob = Whatsapp::TemplateAssetUploadService.find_upload_blob!(
          blob_signed_id,
          account_id: whatsapp_channel.account_id
        )
        raise ArgumentError, 'Uploaded media file is already in use' if blob.attachments.exists?

        return { card_index: card_index, media_type: media_type, blob: blob }
      rescue Whatsapp::TemplateAssetUploadService::BlobReferenceUnavailableError
        # Match the request builder's narrow rolling-deploy fallback to the validated URL.
      end
    end

    raise ArgumentError, "Carousel card #{card_index + 1} media file or URL is required" if source_url.blank?

    { card_index: card_index, media_type: media_type, source_url: source_url }
  end
end
