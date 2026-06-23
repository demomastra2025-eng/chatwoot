class ChangeCrmStageColorDefaultToSpectrum < ActiveRecord::Migration[7.1]
  def change
    change_column_default :crm_stages, :color, from: '#F0F0F3', to: '#E11D48'
  end
end
