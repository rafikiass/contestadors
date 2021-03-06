namespace :uefa do
  namespace :euro2012 do   

    desc "Sets the result of a predictable and updates the prediction scores and score tables"
    task(:update_scores => :environment) do
      ActiveRecord::Base.transaction do

        @contest = Configuration::Contest.where(:name => "UEFA Euro 2012").first
        @score_and_map_reduced_by_user_id = {}
        @user_by_id = {}
        @predictable_types = {:group_matches => "Group Matches", :group_positions => "Group Tables", :stage_teams => "Stage Teams", :winner_teams => "Specific Team"}
        @predictables_by_id = {}
        @predictable_types.keys.each {|predictable_type| @predictables_by_id[predictable_type] = {}}
        @unsettled_items_by_predictable_id = {}

        puts "sets match scores..."
        Rake::Task["uefa:euro2012:set_match_scores"].invoke
        [:group_matches, :stage_teams, :winner_teams].each {|descr| puts "found number of  " + descr.to_s.gsub('_', ' ') + ": " + @predictables_by_id[descr].values.size.to_s if @predictables_by_id.has_key?(descr)}

        puts "sets group table positions..."
        Rake::Task["uefa:euro2012:set_group_positions"].invoke
        puts "found number of group positions: " + @predictables_by_id[:group_positions].values.size.to_s

        puts "sets stage teams..."
        Rake::Task["uefa:euro2012:set_stage_teams"].invoke
        puts "found number of stage teams: " + @predictables_by_id[:stage_teams].values.size.to_s

        @predictable_types.each do |predictable_type, category_descr|
          puts "fetches the corresponding unsettled " + predictable_type.to_s.gsub('_', ' ') + " predictable items..."
          @unsettled_items_by_predictable_id[predictable_type] = Predictable::Championship::PredictableItemsResolver.new(@contest, @predictables_by_id[predictable_type].values).find_items(category_descr)
          puts "found number of unsettled " + predictable_type.to_s.gsub('_', ' ') + " predictable items: " + @unsettled_items_by_predictable_id[predictable_type].size.to_s
        end

        puts "sets prediction score points and objectives meet..."
        Rake::Task["uefa:euro2012:set_prediction_points"].invoke

        puts "updates prediction summaries ..."
        Rake::Task["uefa:euro2012:update_prediction_summaries"].invoke

        puts "update all contest score tables ..."
        @contest.update_all_score_tables

        puts "... score update completed."
      end
    end

    desc "Sets the score and result for matches listed in the CSV file."
    task(:set_match_scores => :environment) do
      file_name = File.join(File.dirname(__FILE__), '/uefa_euro_2012_match_results.csv')
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
      file_name = File.join(File.dirname(__FILE__), '/uefa_euro_2012_group_positions.csv')
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
      file_name = File.join(File.dirname(__FILE__), '/uefa_euro_2012_stage_teams.csv')
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

          winner_set = Configuration::Set.where(:description => "Winner Team").last
          winner_item = winner_set.predictable_items.first
          dependant_items_by_item_id = {}
          map_reduction_value  = nil
          mutex_set_by_set_id = {}

          if items.size > 1
            items.each do |item|
              stage_team = item.predictable
              dependant_items = Predictable::Championship::PredictableItemsResolver.new(@contest, stage_team.dependant_predictables).find_items(category_descr)
              dependant_items_by_item_id[item.id] = dependant_items.values
              dependant_items_by_item_id[item.id] << winner_item
            end

          else
            item = items.first
            stage_team = item.predictable
            match = stage_team.qualified_from_match
            following_stage_teams = Predictable::Championship::StageTeam.stage_teams_after(stage_team.stage)
            dependant_items = Predictable::Championship::PredictableItemsResolver.new(@contest, following_stage_teams).find_items(category_descr)
            dependant_items_by_item_id[item.id] = dependant_items.values
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

    desc "Corrects map for users having predicted Russia as winner"
    task(:correct_map => :environment) do
      russia = Predictable::Championship::Team.where(:name => "Russia").last
      winner_set = Configuration::Set.where(:description => "Winner Team").last
      winner_item = winner_set.predictable_items.first
      predictions = Prediction.where(:configuration_predictable_item_id => winner_item.id, :predicted_value => russia.id.to_s)
      puts "Found " + predictions.count.to_s + " predictions..."
      contest = Configuration::Contest.last

      predictions.each do |prediction|
        user = prediction.user
        summary = user.summary_of(contest)
        puts "Map for user " + user.name + " before correction: " + summary.map.to_s
        summary.map = summary.map - 50
        puts "Map for user " + user.name + " after correction: " + summary.map.to_s
        summary.save!
      end
    end

    desc "Sets up dev application in dev mode"
    task(:dev_setup => :environment) do
      puts "get most recent db changes..."
      Rake::Task["db:migrate"].invoke
      puts "set default password for all users to 'changeit' "
      User.find(:all).each {|user| user.update_attributes(:password => 'changeit', :password_confirmation => 'changeit')}
      puts "correct data error in stage_qualifications table"
      Rake::Task["predictable:championship:correct_stage_qualifications"].invoke
    end

    desc "Correct stage qualifications to set final stage teams as SF match winners, and third place PO stage teams as SF match loosers"
    task(:correct_stage_qualifications => :environment) do
      third_place = Predictable::Championship::Match.find_by_description("Third Place")
      third_place_stage_teams = Predictable::Championship::StageTeam.find(:all, :conditions => {:predictable_championship_match_id => third_place.id})
      stage_team_ids = third_place_stage_teams.collect {|tpst| tpst.id}
      Predictable::Championship::StageQualification.find(:all, :conditions => {:predictable_championship_stage_team_id => stage_team_ids}).each do |qual|
        qual.is_winner = false
        qual.save!
      end
      final = Predictable::Championship::Match.find_by_description("Final")
      final_stage_teams = Predictable::Championship::StageTeam.find(:all, :conditions => {:predictable_championship_match_id => final.id})
      stage_team_ids = final_stage_teams.collect {|tpst| tpst.id}
      Predictable::Championship::StageQualification.find(:all, :conditions => {:predictable_championship_stage_team_id => stage_team_ids}).each do |qual|
        qual.is_winner = true
        qual.save!
      end
    end

    desc "Correcting user with predictions on one account and predictions on another account"
    task(:merge_users => :environment) do
      u1 = User.find(141)
      puts "User 1 " + u1.name
      u2 = User.find(189)
      puts "User 1 " + u2.name
      contest = Configuration::Contest.find(:first)

      ActiveRecord::Base.transaction do
        u1.participations.each do |participation|
          participation.user = u2
          participation.save!
        end
        u1.score_table_positions.each do |stp|
          stp.user = u2
          stp.prediction_summary = u2.summary_of(contest)
          stp.save!
        end
      end
    end

    desc "Correcting predictions placed incorrectly using IE"
    task(:correct_predictions => :environment) do
      user = User.find(76)

# 1/4 finale
#Paraguay - Spania    Spania
#Argentina - Tyskland      Argentina
#Frankrike - England    England
#Holland - Brasil                    Brasil
#
# Semi
#ARG - SPA    Spania
#ENG - BRA         Brasil
#
#  vinner av finalen SPA-BRA?    Spania
#
#  vinner av 3. plass ENG-ARG? Argentina

      paraguay = Predictable::Championship::Team.find_by_name("Paraguay")
      netherlands = Predictable::Championship::Team.find_by_name("Netherlands")
      argentina = Predictable::Championship::Team.find_by_name("Argentina")
      england = Predictable::Championship::Team.find_by_name("England")
      spain = Predictable::Championship::Team.find_by_name("Spain")
      brazil = Predictable::Championship::Team.find_by_name("Brazil")
      france = Predictable::Championship::Team.find_by_name("France")

      set = Configuration::Set.find_by_description("Teams through to Semi finals")
      user.predictions_for(set).each do |prediction|

        if prediction.predicted_value.eql?(netherlands.id.to_s)
          prediction.predicted_value = brazil.id.to_s
          prediction.save!
        elsif prediction.predicted_value.eql?(paraguay.id.to_s)
          prediction.predicted_value = spain.id.to_s
          prediction.save!
        elsif prediction.predicted_value.eql?(france.id.to_s)
          prediction.predicted_value = england.id.to_s
          prediction.objectives_meet = nil
          prediction.received_points = nil
          prediction.save!
        end
      end

      set = Configuration::Set.find_by_description("Teams through to Final")
      user.predictions_for(set).each do |prediction|

        if prediction.predicted_value.eql?(france.id.to_s)
          prediction.predicted_value = brazil.id.to_s
          prediction.objectives_meet = nil
          prediction.received_points = nil
          prediction.save!
        elsif prediction.predicted_value.eql?(argentina.id.to_s)
          prediction.predicted_value = spain.id.to_s
          prediction.save!
        end
      end

      set = Configuration::Set.find_by_description("Third Place Team")
      Prediction.create!(:user_id => user.id,
        :configuration_predictable_item_id => set.predictable_items.first.id,
        :predicted_value => argentina.id.to_s)
#      user.predictions_for(set).each do |prediction|
#        prediction.predicted_value = argentina.id.to_s
#        prediction.save!
#      end

      set = Configuration::Set.find_by_description("Winner Team")
      Prediction.create!(:user_id => user.id,
        :configuration_predictable_item_id => set.predictable_items.first.id,
        :predicted_value => spain.id.to_s)
#      user.predictions_for(set).each do |prediction|
#        prediction.predicted_value = spain.id.to_s
#        prediction.save!
#      end
      contest = Configuration::Contest.find(:first)
      summary = user.summary_of(contest)
      summary.map = summary.map + 16 + 9
      summary.previous_map = summary.previous_map + 16 + 9
      summary.state = "t"
      summary.save!
    end
  end
end
