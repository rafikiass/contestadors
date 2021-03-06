module Predictable
  module Championship
    class Stage < ActiveRecord::Base
      # TODO consider using permalink_fu plugin if other models also requires permalinks
      set_table_name("predictable_championship_stages")
      has_many :matches, :class_name => "Predictable::Championship::Match", :foreign_key => "predictable_championship_stage_id"
      has_many :stage_teams, :class_name => "Predictable::Championship::StageTeam", :foreign_key => "predictable_championship_stage_id"
      has_many :teams, :through => :stage_teams, :class_name => "Predictable::Championship::Team"
      belongs_to :next, :class_name => "Predictable::Championship::Stage", :foreign_key => "next_stage_id"
      has_one :previous, :class_name => "Predictable::Championship::Stage", :foreign_key => "next_stage_id"

      scope :knockout_stages, :conditions => {:description => ["Round of 16", "Quarter finals", "Semi finals", "Final"]}, :order => "id DESC"
      scope :explicit_predicted_knockout_stages, :conditions => {:description => ["Quarter finals", "Semi finals", "Final"]}, :order => "id DESC"

      def self.from_permalink(permalink)
        description = permalink.capitalize.gsub('-', ' ')
        Stage.where(:description => description).last
      end

      def permalink
        description.downcase.gsub(' ', '-')
      end

      def is_final_stage?
        "Final".eql?(self.description)
      end

      # Returns a hash with the matches keyed by the id
      # TODO both in group and stage class, should be refactored out in separate module/plugin
      def matches_by_id
        Hash[*matches.collect{|match| [match.id, match]}.flatten]
      end
    end
  end
end
