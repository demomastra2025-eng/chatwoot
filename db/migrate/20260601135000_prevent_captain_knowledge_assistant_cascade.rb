class PreventCaptainKnowledgeAssistantCascade < ActiveRecord::Migration[7.1]
  def up
    replace_knowledge_cache_assistant_foreign_key
  end

  def down
    replace_knowledge_cache_assistant_foreign_key(on_delete: :cascade)
  end

  private

  def replace_knowledge_cache_assistant_foreign_key(on_delete: nil)
    remove_foreign_key :captain_knowledge_answer_cache_entries, column: :assistant_id if knowledge_cache_assistant_foreign_key_exists?

    options = { column: :assistant_id }
    options[:on_delete] = on_delete if on_delete

    add_foreign_key :captain_knowledge_answer_cache_entries, :captain_assistants, **options
  end

  def knowledge_cache_assistant_foreign_key_exists?
    foreign_key_exists?(
      :captain_knowledge_answer_cache_entries,
      :captain_assistants,
      column: :assistant_id
    )
  end
end
