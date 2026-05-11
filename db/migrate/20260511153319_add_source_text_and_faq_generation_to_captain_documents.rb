class AddSourceTextAndFaqGenerationToCaptainDocuments < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_documents, :source_text, :text
    add_column :captain_documents, :faq_generation_enabled, :boolean, null: false, default: true
  end
end
