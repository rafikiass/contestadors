namespace :fifa do
  namespace :wc2014 do
  
    desc "Corrects score table positions and high score list elements"
    task(:kick_off_maintenance => :environment) do
      ActiveRecord::Base.transaction do

        @contest = Configuration::Contest.find_by_name("FIFA World Cup 2014")
        @contest.high_score_list_positions.each do |hslp|
          hslp.has_predictions = hslp.prediction_summary.has_predictions
          hslp.save!
        end
        
        @contest.contest_instances.each do |instance| 
          instance.score_table_positions.each do |stp|
            stp.position = 1
            stp.save!
          end
        end  
      end    
    end    
  
    desc "Sets the result of a predictable and updates the prediction scores and score tables"
    task(:update_scores => :environment) do
      ActiveRecord::Base.transaction do

        @contest = Configuration::Contest.find_by_name("FIFA World Cup 2014")
        @score_and_map_reduced_by_user_id = {}
        @user_by_id = {}
        @predictable_types = {:group_matches => "Group Matches", :group_positions => "Group Tables", :stage_teams => "Stage Teams", :winner_teams => "Specific Team"}
        @predictables_by_id = {}
        @predictable_types.keys.each {|predictable_type| @predictables_by_id[predictable_type] = {}}
        @unsettled_items_by_predictable_id = {}
        
        puts "sets match scores..."        
        Rake::Task["fifa:wc2014:set_match_scores"].invoke
        [:group_matches, :stage_teams, :winner_teams].each {|descr| puts "found number of  " + descr.to_s.gsub('_', ' ') + ": " + @predictables_by_id[descr].values.size.to_s if @predictables_by_id.has_key?(descr)}

        puts "sets group table positions..."
        Rake::Task["fifa:wc2014:set_group_positions"].invoke
        puts "found number of group positions: " + @predictables_by_id[:group_positions].values.size.to_s

        puts "sets stage teams..."
        Rake::Task["fifa:wc2014:set_stage_teams"].invoke
        puts "found number of stage teams: " + @predictables_by_id[:stage_teams].values.size.to_s
        
        @predictable_types.each do |predictable_type, category_descr|
          puts "fetches the corresponding unsettled " + predictable_type.to_s.gsub('_', ' ') + " predictable items..."
          @unsettled_items_by_predictable_id[predictable_type] = Predictable::Championship::PredictableItemsResolver.new(@contest, @predictables_by_id[predictable_type].values).find_items(category_descr)
          puts "found number of unsettled " + predictable_type.to_s.gsub('_', ' ') + " predictable items: " + @unsettled_items_by_predictable_id[predictable_type].size.to_s
        end

        puts "sets prediction score points and objectives meet..."
        Rake::Task["fifa:wc2014:set_prediction_points"].invoke

        puts "updates prediction summaries ..."
        Rake::Task["fifa:wc2014:update_prediction_summaries"].invoke

        puts "update all contest score tables ..."
        @contest.update_all_score_tables
        
        puts "update tournament high score list ..."
        @contest.update_high_score_list_positions

        puts "... score update completed."
      end
    end  
    
    desc "Sets the score and result for matches listed in the CSV file."
    task(:set_match_scores => :environment) do
      file_name = File.join(File.dirname(__FILE__), '/fifa_world_cup_2014_match_results.csv')
      parser = CSV.new(File.open(file_name, 'r'),
                             :headers => true, :header_converters => :symbol,
                             :col_sep => ',')

      parser.each do |row|
        home_team = Predictable::Championship::Team.where(:name => row.field(:home_team_name)).last
        away_team = Predictable::Championship::Team.where(:name => row.field(:away_team_name)).last
        match = Predictable::Championship::Match.where(:description => row.field(:match_descr), :home_team_id => home_team.id, :away_team_id => away_team.id).last
        match ||= Predictable::Championship::Match.where(:description => row.field(:match_descr), :home_team_id => away_team.id, :away_team_id => home_team.id).last
        match.settle_match(row.field(:score))
        puts "... score and result set for match " + match.home_team.name + " - " + match.away_team.name + " " + match.score + " (" + match.result + ")"
        if match.is_group_match?
          @predictables_by_id[:group_matches][match.id] = match
        else
          stage_team = match.winner_stage_team

          if stage_team
            @predictables_by_id[:stage_teams][stage_team.id] = stage_team
          else
            @predictables_by_id[:winner_teams][match.id] = match
          end
        end
      end
    end  
    
    desc "Sets the score and result for matches listed in the CSV file."
    task(:set_group_positions => :environment) do
      file_name = File.join(File.dirname(__FILE__), '/fifa_world_cup_2014_group_positions.csv')
      parser = CSV.new(File.open(file_name, 'r'),
                             :headers => true, :header_converters => :symbol,
                             :col_sep => ',')

      parser.each do |row|
        group = Predictable::Championship::Group.where(:name => row.field(:group)).last
        puts "Found group: " + group.name
        team = Predictable::Championship::Team.where(:name => row.field(:team)).last
        puts "Found team: " + team.name
        group_table_position = Predictable::Championship::GroupTablePosition.where(:predictable_championship_group_id => group.id, :predictable_championship_team_id => team.id).last
        group_table_position.settle(row.field(:pos))
        
        puts group_table_position.pos.to_s + ". position group " + group_table_position.group.name + ": " + group_table_position.team.name
        @predictables_by_id[:group_positions][group_table_position.id] = group_table_position
      end
    end

    desc "Sets the score and result for matches listed in the CSV file."
    task(:set_stage_teams => :environment) do
      file_name = File.join(File.dirname(__FILE__), '/fifa_world_cup_2014_stage_teams.csv')
      parser = CSV.new(File.open(file_name, 'r'),
                             :headers => true, :header_converters => :symbol,
                             :col_sep => ',')

      parser.each do |row|
        stage = Predictable::Championship::Stage.where(:description => row.field(:stage)).last
        team = Predictable::Championship::Team.where(:name => row.field(:team)).last
        
        if stage and team
          stage_team = Predictable::Championship::StageTeam.where(:predictable_championship_stage_id => stage.id, :predictable_championship_team_id => team.id).last

          puts "Stage: " + stage_team.stage.description + ", Team: " + stage_team.team.name
          @predictables_by_id[:stage_teams][stage_team.id] = stage_team
        end
      end
    end    
  
    desc "Calculates points for all predictions of unsettled group match predictable items."
    task(:set_prediction_points => :environment) do
      @predictable_types.each do |predictable_type, category_descr|
        
        if "Stage Teams".eql?(category_descr)
          items = @unsettled_items_by_predictable_id[predictable_type].values
          next if items.empty?
          
          third_place_set = Configuration::Set.where(:description => "Third Place Team").last
          third_place_item = third_place_set.predictable_items.first
          winner_set = Configuration::Set.where(:description => "Winner Team").last
          winner_item = winner_set.predictable_items.first
          dependant_items_by_item_id = {}
          map_reduction_value  = nil
          final_teams_set = Configuration::Set.where(:description => "Teams through to Final").last
          mutex_set_by_set_id = {final_teams_set.id => third_place_set}
          
          if items.size > 1
            items.each do |item|
              stage_team = item.predictable
              dependant_items = Predictable::Championship::PredictableItemsResolver.new(@contest, stage_team.dependant_predictables).find_items(category_descr)
              dependant_items_by_item_id[item.id] = dependant_items.values
              dependant_items_by_item_id[item.id] << third_place_item
              dependant_items_by_item_id[item.id] << winner_item
            end

          else
            item = items.first
            stage_team = item.predictable
            match = stage_team.qualified_from_match
            following_stage_teams = Predictable::Championship::StageTeam.stage_teams_after(stage_team.stage)
            dependant_items = Predictable::Championship::PredictableItemsResolver.new(@contest, following_stage_teams).find_items(category_descr)
            dependant_items_by_item_id[item.id] = dependant_items.values
            dependant_items_by_item_id[item.id] << third_place_item
            dependant_items_by_item_id[item.id] << winner_item
            map_reduction_value = match.losing_team.id.to_s
          end

          puts "... settles items for set " + items.first.description
          Configuration::PredictableItem.settle_predictions_for(items, dependant_items_by_item_id, map_reduction_value, mutex_set_by_set_id) do |user, score, map_reduction|
            unless @user_by_id.has_key?(user.id)
              @user_by_id[user.id] = user
              @score_and_map_reduced_by_user_id[user.id] = {:score => score, :map_reduction => map_reduction}
            else
              @score_and_map_reduced_by_user_id[user.id][:score] += score
              @score_and_map_reduced_by_user_id[user.id][:map_reduction] += map_reduction
            end
          end
#        elsif "Specific Team".eql?(category_descr)
#
#          @unsettled_items_by_predictable_id[predictable_type].values.each do |item|
#            puts "... settles one item for set " + item.description
#            item.settle_predictions_for(@predictables_by_id[predictable_type][item.predictable_id]) do |user, score, map_reduction|
#              unless @user_by_id.has_key?(user.id)
#                @user_by_id[user.id] = user
#                @score_and_map_reduced_by_user_id[user.id] = {:score => score, :map_reduction => 0}
#              else
#                @score_and_map_reduced_by_user_id[user.id][:score] += score
#              end
#            end
#          end

        else
          # Group Matches, Group Table and Specific Team categories
          if "Specific Team".eql?(category_descr)
            items = @unsettled_items_by_predictable_id[predictable_type].values
            next if items.empty?
            map_reduction_value = items.first.predictable.losing_team.id.to_s
          end

          @unsettled_items_by_predictable_id[predictable_type].values.each do |item|
            puts "... settles one item for set " + item.description
            item.settle_predictions_for(@predictables_by_id[predictable_type][item.predictable_id]) do |prediction, score, map_reduction|
              user = prediction.user
              
              if map_reduction_value

                unless map_reduction_value.eql?(prediction.predicted_value)
                  map_reduction = 0
                end
              end

              unless @user_by_id.has_key?(user.id)
                @user_by_id[user.id] = user
                @score_and_map_reduced_by_user_id[user.id] = {:score => score, :map_reduction => map_reduction}
              else
                @score_and_map_reduced_by_user_id[user.id][:score] += score
                @score_and_map_reduced_by_user_id[user.id][:map_reduction] += map_reduction
              end
            end
          end
        end
      end
    end  
  
    desc "Updates the prediction summaries of all users having prediction points set."
    task(:update_prediction_summaries => :environment) do
      @user_by_id.values.each do |user|
        score = @score_and_map_reduced_by_user_id[user.id][:score]
        map_reduction = @score_and_map_reduced_by_user_id[user.id][:map_reduction]
        summary = user.summary_of(@contest)

        if summary
          summary.update_score_and_map_values(score, map_reduction)
          puts "prediction summary updated for " + user.name
        end
      end
    end 
    
    desc "Corrects score table positions and high score list elements"
    task(:add_users_to_contests => :environment) do 
      ci = ContestInstance.find(149)
      ['per.sletten@enviropac.no'].each do |e|
        user = User.where(:email => e).first
	    participation = Participation.new(:user_id => user.id,
	   								  :contest_instance_id => ci.id,
									  :active => true)
        participation.save!        
	  end
    end
    
    
    desc "Correcting predictions placed incorrectly using IE"
    task(:correct_predictions => :environment) do
      user = User.find(492)

# 1/4 finale
#Brazil - Colombia    Brazil
#France - Germany     Germany
#Croatia - Italy      Croatia
#Argentina - Portugal Argentina
#
# Semi
#Brazil - Germany      Brazil
#Croatia - Argentina   Argentina
#
#  vinner av finalen Brazil - Argentina?    Argentina
#
#  vinner av 3. plass Germany - Croatia?    Germany

      brazil = Predictable::Championship::Team.where(:name => "Brazil").last
      colombia = Predictable::Championship::Team.where(:name => "Colombia").last
      france = Predictable::Championship::Team.where(:name => "France").last
      germany = Predictable::Championship::Team.where(:name => "Germany").last
      croatia = Predictable::Championship::Team.where(:name => "Croatia").last
      italy = Predictable::Championship::Team.where(:name => "Italy").last
      argentina = Predictable::Championship::Team.where(:name => "Argentina").last
      portugal = Predictable::Championship::Team.where(:name => "Portugal").last

      ActiveRecord::Base.transaction do
	  #Home team Quarter final match 4th July 17:00
	  item = Configuration::PredictableItem.find(380)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => brazil.id.to_s) 
	  #Away team Quarter final match 4th July 17:00
	  item = Configuration::PredictableItem.find(381)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => colombia.id.to_s)         
		
	  #Home team Quarter final match 4th July 13:00
	  item = Configuration::PredictableItem.find(378)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => france.id.to_s)        
	  #Away team Quarter final match 4th July 13:00
	  item = Configuration::PredictableItem.find(379)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => germany.id.to_s)

	  #Home team Quarter final match 5th July 17:00
	  item = Configuration::PredictableItem.find(384)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => croatia.id.to_s)
	  #Away team Quarter final match 5th July 17:00
	  item = Configuration::PredictableItem.find(385)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => italy.id.to_s)        

	  #Home team Quarter final match 5th July 13:00
	  item = Configuration::PredictableItem.find(382)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => argentina.id.to_s)
	  #Away team Quarter final match 5th July 13:00
	  item = Configuration::PredictableItem.find(383)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => portugal.id.to_s)        
					 
	  #Home team Semi final match 8th July 17:00  
	  item = Configuration::PredictableItem.find(386)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => brazil.id.to_s)
	  #Away team Semi final match 8th July 17:00  
	  item = Configuration::PredictableItem.find(387)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => germany.id.to_s)
				
	  #Home team Semi final match 9th July 17:00  
	  item = Configuration::PredictableItem.find(388)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => argentina.id.to_s)                            
	  #Away team Semi final match 9th July 17:00  
	  item = Configuration::PredictableItem.find(389)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => croatia.id.to_s)                 
		
	  #Home team Final match 13th July 16:00
	  item = Configuration::PredictableItem.find(390)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => brazil.id.to_s)
	  #Away team Final match 4th July 17:00
	  item = Configuration::PredictableItem.find(391)
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => item.id,
		:predicted_value => argentina.id.to_s)                    

	  set = Configuration::Set.where(:description => "Third Place Team").last
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => set.predictable_items.first.id,
		:predicted_value => germany.id.to_s)

	  set = Configuration::Set.where(:description => "Winner Team").last
	  Prediction.create!(:user_id => user.id,
		:configuration_predictable_item_id => set.predictable_items.first.id,
		:predicted_value => argentina.id.to_s)

	  contest = Configuration::Contest.last
	  summary = user.summary_of(contest)
	  summary.map = summary.map + 48 + 36 + 32 + 16 + 32
	  summary.previous_map = summary.previous_map + 48 + 36 + 32 + 16 + 32
	  summary.state = "t"
	  summary.save!
      end
    end    
  end
end  
  
