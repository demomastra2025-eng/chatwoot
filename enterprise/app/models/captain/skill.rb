# == Schema Information
#
# Table name: captain_skills
#
#  id          :bigint           not null, primary key
#  content     :text             not null
#  description :text             not null
#  group_name  :string
#  metadata    :jsonb            not null
#  name        :string           not null
#  slug        :string           not null
#  source_url  :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_captain_skills_on_account_id           (account_id)
#  index_captain_skills_on_account_id_and_slug  (account_id,slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class Captain::Skill < ApplicationRecord
  self.table_name = 'captain_skills'

  MAX_CONTENT_BYTES = 200.kilobytes
  MAX_DESCRIPTION_BYTES = 10.kilobytes
  MAX_NAME_LENGTH = 120
  DEFAULT_GROUP_NAME = 'Workspace Skills'.freeze

  belongs_to :account

  before_validation :ensure_slug
  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :slug, presence: true, uniqueness: { scope: :account_id }
  validates :description, presence: true, length: { maximum: MAX_DESCRIPTION_BYTES }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_BYTES }
  validate :metadata_must_be_hash

  scope :ordered, -> { order(updated_at: :desc, id: :desc) }
  scope :search, lambda { |query|
    next all if query.blank?

    term = "%#{sanitize_sql_like(query)}%"
    where('name ILIKE :term OR description ILIKE :term OR content ILIKE :term OR group_name ILIKE :term', term: term)
  }

  class << self
    def normalize_slug(value)
      normalized = value.to_s.parameterize
      normalized.presence || "skill-#{Digest::SHA256.hexdigest(value.to_s).slice(0, 12)}"
    end

    def attributes_from_markdown(markdown, source_url: nil)
      frontmatter, body = parse_frontmatter(markdown)
      name = sanitize_metadata(frontmatter['name'])
      description = sanitize_metadata(frontmatter['description'])

      invalid_record!(:name, 'is missing in SKILL.md frontmatter') if name.blank?
      invalid_record!(:description, 'is missing in SKILL.md frontmatter') if description.blank?

      {
        name: name,
        slug: normalize_slug(name),
        description: description,
        content: body.to_s.strip,
        group_name: sanitize_metadata(frontmatter.dig('metadata', 'category')).presence || DEFAULT_GROUP_NAME,
        source_url: source_url,
        metadata: frontmatter['metadata'].is_a?(Hash) ? frontmatter['metadata'] : {}
      }
    end

    def parse_frontmatter(raw)
      match = raw.to_s.match(/\A---\r?\n(?<yaml>[\s\S]*?)\r?\n---\r?\n?(?<content>[\s\S]*)\z/)
      return [{}, raw.to_s] unless match

      frontmatter = YAML.safe_load(match[:yaml], aliases: false) || {}
      [frontmatter.is_a?(Hash) ? frontmatter.deep_stringify_keys : {}, match[:content].to_s]
    rescue Psych::Exception
      [{}, raw.to_s]
    end

    def sanitize_metadata(value)
      value.to_s.gsub(/\e\[[\d;]*[A-Za-z]/, '').gsub(/[\r\n]+/, ' ').strip
    end

    def invalid_record!(attribute, message)
      skill = new
      skill.errors.add(attribute, message)
      raise ActiveRecord::RecordInvalid, skill
    end
  end

  def to_catalog_entry
    {
      id: slug,
      title: name,
      description: description,
      group_name: group_name.presence || DEFAULT_GROUP_NAME,
      source_path: source_url,
      source_url: source_url,
      content: content.to_s.strip,
      scripts: [],
      tree: [],
      editable: true,
      source_type: 'workspace',
      workspace_skill_id: id
    }
  end

  def as_api_json
    to_catalog_entry.merge(
      name: name,
      slug: slug,
      created_at: created_at.to_i,
      updated_at: updated_at.to_i
    )
  end

  private

  def ensure_slug
    self.slug = self.class.normalize_slug(name) if slug.blank? && name.present?
  end

  def normalize_fields
    self.name = self.class.sanitize_metadata(name)
    self.group_name = self.class.sanitize_metadata(group_name).presence || DEFAULT_GROUP_NAME
    self.description = self.class.sanitize_metadata(description)
    self.content = content.to_s.strip
    self.metadata = metadata.presence || {}
  end

  def metadata_must_be_hash
    errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
  end
end
