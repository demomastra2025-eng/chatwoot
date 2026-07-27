require 'rails_helper'

RSpec.describe ReminderGroup do
  it 'preserves an omitted step id on update' do
    group = create(:reminder_group)
    original_step_id = group.touches.first['step_id']

    group.update!(touches: [group.touches.first.except('step_id').merge('body' => 'Updated body')])

    expect(group.reload.touches.first['step_id']).to eq(original_step_id)
  end
end
