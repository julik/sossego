class CreateCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :counters do |t|
      t.string :name, null: false
      t.integer :value, null: false, default: 0
      t.timestamps
    end
  end
end
