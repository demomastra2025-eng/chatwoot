namespace :medelement do
  desc 'Capture sanitized, read-only MedElement schedule samples for one hook'
  task :capture_samples, [:hook_id] => :environment do |_task, args|
    hook_id = args[:hook_id].to_s
    abort 'Capture refused: hook_id must be a numeric hook id' unless hook_id.match?(/\A[1-9]\d*\z/)

    hook = Integrations::Hook.find_by(id: hook_id, app_id: 'medelement')
    abort 'Capture refused: MedElement hook not found' unless hook

    capture = Integrations::Medelement::SampleCapture.new(
      hook: hook,
      max_doctors: ENV.fetch('MAX_DOCTORS', Integrations::Medelement::SampleCapture::MAX_DOCTORS),
      max_requests: ENV.fetch('MAX_REQUESTS', Integrations::Medelement::SampleCapture::MAX_REQUESTS)
    )
    directory = capture.perform
    puts directory
    puts capture.summary
  rescue Integrations::Medelement::SampleCapture::Refused => e
    abort "Capture refused: #{e.message}"
  rescue StandardError
    abort 'Capture failed. No exception details were printed; inspect the sanitized output if a directory was created.'
  end
end
