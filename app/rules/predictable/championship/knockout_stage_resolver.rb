module Predictable
  module Championship

    class KnockoutStageResolver
      include Ruleby

      def initialize(user)
        @stages = Predictable::Championship::Stage.knockout_stages
        @teams = Predictable::Championship::Team.find(:all)        
        @predictable_items = stage_predictable_items
        @predictions = user.predictions.for_items(@predictable_items)
        @third_place_play_off = Predictable::Championship::Match.find_by_description("Third Place")#@aggregate.associated
      end

      def predicted_stages(current_aggregate)
        @predicted_stages = {}

        engine :predicted_stage_matches do |e|
          KnockoutStageRulebook.new(e).rules(@predicted_stages)

          @teams.each {|team| e.assert team}
          @stages.each do |stage|
            stage.matches.each {|stage_match| e.assert stage_match}
            stage.stage_teams.each {|stage_team| e.assert stage_team}
            e.assert stage
          end
          
          @predictions.each{|prediction| e.assert prediction}
          @predictable_items.each{|item| e.assert item}
          e.assert @third_place_play_off
          
          e.match
        end

        result = Predictable::Result.new(current_aggregate, @predicted_stages, unpredicted_stages, invalidated_stages(current_aggregate))
        result.all_roots = @stages
        resolve_third_place_play_off if is_semi_finals_predicted?
        result.aggregates_associated(:third_place, @third_place_play_off)
        result
      end

    private

      def stage_predictable_items
        ["Stage Teams", "Specific Team"].collect{|category_descr| Configuration::Category.find_by_description(category_descr)}.collect{|category| category.predictable_items}.flatten
      end

      def unpredicted_stages
        unpredicted = {}
        @stages.each {|stage| unpredicted[stage.id] = stage unless @predicted_stages.has_key?(stage.id)}
        unpredicted
      end

      def invalidated_stages(current_aggregate)
        invalidated_stages = {}
        current_stage = current_aggregate.root

        while current_stage and current_stage.next do
          next_stage = current_stage.next
          invalidated_stages[next_stage.id] = next_stage if @predicted_stages.has_key?(next_stage.id)
          current_stage = next_stage
        end
        invalidated_stages
      end

      # TODO ruleify
      def is_semi_finals_predicted?
        @predicted_stages.size > 2
      end

      # TODO ruleify
      def resolve_third_place_play_off
        semi_final_defeated_teams = []

        semi_finals_stage = Predictable::Championship::Stage.find_by_description("Semi finals")
        @predicted_stages[semi_finals_stage.id].matches.each {|match| semi_final_defeated_teams << match.team_not_through_to_next_stage}

        if semi_final_defeated_teams.size == 2
          @third_place_play_off.home_team = semi_final_defeated_teams[0]
          @third_place_play_off.away_team = semi_final_defeated_teams[1]
        end
      end
    end
  end
end
