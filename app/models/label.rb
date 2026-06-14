# == Schema Information
#
# Table name: labels
#
#  id              :bigint           not null, primary key
#  color           :string           default("#1f93ff"), not null
#  description     :text
#  display_title   :string
#  emoji           :string
#  marker_type     :string           default("color"), not null
#  show_on_sidebar :boolean
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint
#
# Indexes
#
#  index_labels_on_account_id            (account_id)
#  index_labels_on_title_and_account_id  (title,account_id) UNIQUE
#
require 'securerandom'

class Label < ApplicationRecord
  include RegexHelper
  include AccountCacheRevalidator

  MARKER_COLOR = 'color'.freeze
  MARKER_EMOJI = 'emoji'.freeze
  MARKER_TYPES = [MARKER_COLOR, MARKER_EMOJI].freeze
  DISPLAY_TITLE_MAX_LENGTH = 120
  GENERATED_TITLE_PREFIX = 'label'.freeze

  belongs_to :account

  validates :title,
            presence: { message: I18n.t('errors.validations.presence') },
            format: { with: UNICODE_CHARACTER_NUMBER_HYPHEN_UNDERSCORE },
            uniqueness: { scope: :account_id }
  validates :display_title,
            presence: { message: I18n.t('errors.validations.presence') },
            length: { maximum: DISPLAY_TITLE_MAX_LENGTH },
            format: { without: /[[:cntrl:]]/ }
  validates :marker_type, inclusion: { in: MARKER_TYPES }
  validates :emoji, presence: true, if: :emoji_marker?

  after_update_commit :update_associated_models
  default_scope { order(:display_title, :title) }

  before_validation :normalize_label_fields

  def conversations
    account.conversations.tagged_with(title)
  end

  def contacts_count
    account.contacts.tagged_with(title).count
  end

  def messages
    account.messages.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    account.reporting_events.where(conversation_id: conversations.pluck(:id))
  end

  def emoji_marker?
    marker_type == MARKER_EMOJI
  end

  private

  def normalize_label_fields
    self.marker_type = MARKER_COLOR unless MARKER_TYPES.include?(marker_type)
    self.display_title = normalized_display_title
    self.title = generated_title if title.blank?
    self.title = title.downcase if attribute_present?('title')
    self.emoji = nil unless emoji_marker?
  end

  def normalized_display_title
    candidate = display_title.to_s.strip
    return candidate if candidate.present?

    title.to_s.strip
  end

  def generated_title
    loop do
      candidate = "#{GENERATED_TITLE_PREFIX}_#{SecureRandom.hex(6)}"
      return candidate unless account&.labels&.exists?(title: candidate)
    end
  end

  def update_associated_models
    return unless title_previously_changed?

    Labels::UpdateJob.perform_later(title, title_previously_was, account_id)
  end
end
