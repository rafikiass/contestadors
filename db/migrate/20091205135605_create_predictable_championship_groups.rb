class CreatePredictableChampionshipGroups < ActiveRecord::Migration
  def self.up
    create_table :predictable_championship_groups do |t|
      t.string :name
      t.timestamps
    end
  end

  def self.down
    drop_table :predictable_championship_groups
  end
end
