module Predictable
  module Championship
    class PredictionCollector
      include Ruleby

      def initialize(user=nil)
        @user = user
#        @summary = {:groups => {}, :stages => {}}
#        ('A'..'H').each {|group_name| @summary[:groups][group_name] = {:matches => [], :table => {}}}
#        ["Round of 16", "Quarter finals", "Semi finals", "Final"].each {|stage| @summary[:stages][stage] = {:teams => []}}
#        @summary[:stages]["Final"].merge(:winner_team => nil)
#        @summary[:stages]["Third Place"] = {:winner_team => nil}
      end

      # returns a prediction summary for the given user, a nested hash map with the following structure:
      # {:groups => {:a => {:matches => [Match1, Match2,..,Match6], :table => [Position1, ..., Position4]},
      #             {:b => {:matches => [Match1, Match2,..,Match6], :table => [Position1, ..., Position4]}},
      #             ...
      #  :stages => {:round-of-16 => {:teams => [Team1, Team2, .., Team8]}},...,
      #            {:final => {:teams => [Team1, Team2], :winner => Team2}},
      #            {:third-place => {:teams => [Team1, Team2], :winner => Team2}}
      #  }
      def get_all
        init_user_summary

        engine :prediction_collection do |e|
          rulebook = PredictionMapperRulebook.new(e)
          rulebook.summary = @summary
          rulebook.rules

          @user.predictions.each {|prediction| e.assert prediction}
          Configuration::PredictableItem.find(:all).each {|item| e.assert item}
          Predictable::Championship::Stage.find_by_description("Group").matches.each {|match| e.assert match}
          ["Final", "Third Place"].each {|match_descr| e.assert Predictable::Championship::Match.find_by_description(match_descr)}
          Predictable::Championship::GroupTablePosition.find(:all).each {|pos| e.assert pos}
          Predictable::Championship::Team.find(:all).each {|team| e.assert team}

          e.match          
        end
        @summary
      end

      # return a nested hash with the predictable item as key and the value an inner hash keyed by
      # participant name and with the predicted score as value
      def get_all_upcoming(participants)
        upcomming_matches = Predictable::Championship::Match.upcomming
        items_by_match_id = Predictable::Championship::PredictableItemsResolver.new(upcomming_matches).find_items
        collect_participant_predictions_by_predictable(upcomming_matches, items_by_match_id, participants)
      end

      def get_all_latest(participants)
        latest_matches = Predictable::Championship::Match.latest
        items_by_match_id = Predictable::Championship::PredictableItemsResolver.new(latest_matches, :processed).find_items
        collect_participant_predictions_by_predictable(latest_matches, items_by_match_id, participants)
      end

    private

      def init_user_summary
        @summary = {:groups => {}, :stages => {}}
        ('A'..'H').each {|group_name| @summary[:groups][group_name] = {:matches => [], :table => {}}}
        ["Round of 16", "Quarter finals", "Semi finals", "Final"].each {|stage| @summary[:stages][stage] = {:teams => []}}
        @summary[:stages]["Final"].merge(:winner_team => nil)
        @summary[:stages]["Third Place"] = {:winner_team => nil}
      end

      def collect_participant_predictions_by_predictable(predictables, items_by_predictable_id, participants)
        participant_predictions_by_predictable = {}
        
        predictables.each do |predictable|
          item = items_by_predictable_id[predictable.id]
          predictions_by_participant_name = {}

          participants.each do |participant|
            prediction = participant.prediction_for(item)
            predictions_by_participant_name[participant.name] = prediction if prediction
          end
          participant_predictions_by_predictable[predictable] = predictions_by_participant_name
        end
        participant_predictions_by_predictable
      end

      class PredictionMapperRulebook < Ruleby::Rulebook

        attr_accessor :summary

        def rules
          
          ("A".."H").each do |group_name|
             group_set = Configuration::Set.find_by_description("Group " + group_name + " Matches")

             rule :set_predicted_group_matches, {:priority => 4},
               [Configuration::PredictableItem, :group_match_item,
                 m.configuration_set_id == group_set.id,
                {m.predictable_id => :group_match_id, m.id => :group_match_item_id}],
               [Prediction, :prediction,
                 m.configuration_predictable_item_id == b(:group_match_item_id)],
               [Predictable::Championship::Match, :group_match,
                 m.id == b(:group_match_id)] do |v|

                 v[:group_match].score = v[:prediction].predicted_value
                 v[:group_match].objectives_meet = v[:prediction].objectives_meet if v[:group_match_item].processed?
                 @summary[:groups][group_name][:matches] << v[:group_match]
                 retract v[:group_match]
                 retract v[:prediction]
                 retract v[:group_match_item]              
            end

            table_set = Configuration::Set.find_by_description("Group " + group_name + " Table")
            rule :set_predicted_group_matches, {:priority => 3},
               [Configuration::PredictableItem, :table_position_item,
                 m.configuration_set_id == table_set.id,
                {m.predictable_id => :table_position_id, m.id => :table_position_item_id}],
               [Prediction, :prediction,
                 m.configuration_predictable_item_id == b(:table_position_item_id)],
               [Predictable::Championship::GroupTablePosition, :table_position,
                 m.id == b(:table_position_id)] do |v|

                 @summary[:groups][group_name][:table][v[:prediction].predicted_value] = v[:table_position].team.name
                 retract v[:table_position]
                 retract v[:prediction]
                 retract v[:table_position_item]
            end
          end

          ["Round of 16", "Quarter finals", "Semi finals", "Final"].each do |stage|
            stage_set = Configuration::Set.find_by_description("Teams through to " + stage)
            
            rule :set_predicted_group_matches, {:priority => 2},
               [Configuration::PredictableItem, :stage_team_item,
                 m.configuration_set_id == stage_set.id,
                {m.id => :stage_team_item_id}],
               [Prediction, :prediction,
                 m.configuration_predictable_item_id == b(:stage_team_item_id),
                {m.predicted_value => :team_id}],
               [Predictable::Championship::Team, :team,
                 m.id(:team_id, &c{|id,tid| id.to_s.eql?(tid)})] do |v|

                 @summary[:stages][stage][:teams] << v[:team]
                 retract v[:stage_team_item]
                 retract v[:prediction]
                 modify v[:team]

#                 if "Final".eql?(stage)
#                   ["Final", "Third Place"].each {|match_descr| assert Predictable::Championship::Match.find_by_description(match_descr)}
#                 end
            end
          end

          {"Final" => "Winner Team", "Third Place" => "Third Place Team"}.each do |match_descr, set_descr|

            rule :resolve_match_winner, {:priority => 1},
               [Predictable::Championship::Match, :match,
                  m.description == match_descr,
                 {m.id => :match_id}],
               [Configuration::PredictableItem, :stage_team_item,
                  m.description == set_descr,
                  m.predictable_id == b(:match_id),
                 {m.id => :winner_item_id}],
               [Prediction, :winner_prediction,
                  m.configuration_predictable_item_id == b(:winner_item_id),
                 {m.predicted_value => :team_id}],
               [Predictable::Championship::Team, :team, m.id(:team_id, &c{|id,tid| id.to_s.eql?(tid)})] do |v|

#              puts "**** Winner of " + match_descr + ": " + v[:team].name
#              v[:match].winner = v[:team]
                 @summary[:stages][match_descr][:winner_team] = v[:team]
                 retract v[:match]
                 retract v[:stage_team_item]
                 retract v[:winner_prediction]
                 retract v[:team]
            end
          end
        end
      end
    end
  end
end