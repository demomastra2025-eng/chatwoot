namespace :captain do
  namespace :knowledge do
    desc 'Backfill/reindex Captain document chunk embeddings. Optional ACCOUNT_ID and ASSISTANT_ID.'
    task reindex_chunks: :environment do
      result = Captain::Documents::ChunkEmbeddingBackfillService.new(
        account_id: ENV['ACCOUNT_ID'],
        assistant_id: ENV['ASSISTANT_ID']
      ).perform

      puts "Captain document chunk embedding jobs enqueued: #{result[:enqueued]}"
    end
  end
end
