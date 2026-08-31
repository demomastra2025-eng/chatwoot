# == Schema Information
#
# Table name: whatsapp_template_media_sources
#
#  id                     :bigint           not null, primary key
#  card_index             :integer          not null
#  language               :string           not null
#  media_type             :string           not null
#  meta_media_uploaded_at :datetime
#  source_url             :text
#  template_name          :string           not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  meta_media_id          :string
#  whatsapp_channel_id    :bigint           not null
#
# Indexes
#
#  idx_wa_template_media_source_identity                         (whatsapp_channel_id,template_name,language,card_index) UNIQUE
#  index_whatsapp_template_media_sources_on_whatsapp_channel_id  (whatsapp_channel_id)
#
# Foreign Keys
#
#  fk_rails_...  (whatsapp_channel_id => channel_whatsapp.id) ON DELETE => cascade
#
class Whatsapp::TemplateMediaSource < ApplicationRecord
  self.table_name = 'whatsapp_template_media_sources'

  MEDIA_TYPES = %w[image video].freeze

  belongs_to :whatsapp_channel, class_name: 'Channel::Whatsapp', inverse_of: :template_media_sources
  has_one_attached :file

  validates :template_name, :language, :media_type, presence: true
  validates :card_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :media_type, inclusion: { in: MEDIA_TYPES }
  validates :card_index, uniqueness: { scope: [:whatsapp_channel_id, :template_name, :language] }
end
