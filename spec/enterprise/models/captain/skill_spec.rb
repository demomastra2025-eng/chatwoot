require 'rails_helper'

RSpec.describe Captain::Skill do
  describe '.attributes_from_markdown' do
    it 'extracts metadata and body from SKILL.md frontmatter' do
      markdown = <<~MARKDOWN
        ---
        name: Follow up
        description: Follow up customers without losing context
        metadata:
          category: Sales
        ---
        Keep the answer short.
      MARKDOWN

      attributes = described_class.attributes_from_markdown(markdown, source_url: 'https://example.com/SKILL.md')

      expect(attributes).to include(
        name: 'Follow up',
        slug: 'follow-up',
        description: 'Follow up customers without losing context',
        group_name: 'Sales',
        source_url: 'https://example.com/SKILL.md',
        content: 'Keep the answer short.'
      )
    end

    it 'rejects markdown without required skill metadata' do
      expect do
        described_class.attributes_from_markdown('No frontmatter')
      end.to raise_error(ActiveRecord::RecordInvalid, /Name is missing/)
    end
  end

  describe '#to_catalog_entry' do
    it 'exposes workspace skills as editable catalog items' do
      skill = build(:captain_skill, id: 42, name: 'Demo Skill', slug: 'demo-skill')

      expect(skill.to_catalog_entry).to include(
        id: 'demo-skill',
        title: 'Demo Skill',
        editable: true,
        source_type: 'workspace',
        workspace_skill_id: 42
      )
    end
  end
end
