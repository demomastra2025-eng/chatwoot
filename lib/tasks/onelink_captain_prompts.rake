namespace :onelink do
  namespace :captain do
    desc 'Write the prompts v2 of one clinic from a JSON file {account_id, shared_block, assistants: [{id, routing_description, ' \
         'description}]}: the clinic context and the prompt and card of every listed agent. Dry run by default (prints unified ' \
         'diffs); apply=true writes all of it in one transaction. Usage: rake "onelink:captain:apply_prompts_v2[path/to/file.json,true]"'
    task :apply_prompts_v2, %i[json_path apply] => :environment do |_task, args|
      apply = args[:apply].to_s.strip.downcase
      abort("REFUSED: apply must be true or false, not #{args[:apply].inspect}") unless ['', 'true', 'false'].include?(apply)

      Captain::PromptsV2Import.new(path: args[:json_path]).call(apply: apply == 'true')
    rescue Captain::PromptsV2Import::Refused => e
      abort("REFUSED, nothing was written:\n#{e.message}")
    end
  end
end
