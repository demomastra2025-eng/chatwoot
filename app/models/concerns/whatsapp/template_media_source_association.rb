module Whatsapp::TemplateMediaSourceAssociation
  extend ActiveSupport::Concern

  included do
    has_many :template_media_sources,
             class_name: 'Whatsapp::TemplateMediaSource',
             foreign_key: :whatsapp_channel_id,
             dependent: :destroy,
             inverse_of: :whatsapp_channel
  end
end
