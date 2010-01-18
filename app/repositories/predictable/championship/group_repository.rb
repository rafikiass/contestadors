# Repository implementation of the root aggregate for predictions related to a
# Predictable::Championship::Group, i.e., group matches and table positions.
# Ref.: http://martinfowler.com/eeaCatalog/repository.html
module Predictable
  module Championship
    class GroupRepository
      # sets the user for which the predictions belongs, the group and the prediction sets
      # defining this aggregate of predictions
      def initialize(user=nil, group_name="A")
        @user = user
        @group = Group.find_by_name group_name
        @group_matches_set = Configuration::Set.find_by_description "Group #{@group.name} Matches"
        @group_table_set = Configuration::Set.find_by_description "Group #{@group.name} Table"
      end

      # retreives the group with the predicted values, or default values if not
      # been predicted by the user (or if no  user is specified, i.e., not signed in
      # guest user)
      def get
        if @user
          return group_from_existing_predictions
        end
        [@group, false]
      end

      # saves the predictions in the provided input hash if the user is signed in
      # If not signed in, the group instance variable will only be updated with the
      # predicted values, and these will not be saved in the db
      def save(predicted_group)
        @group = group_from_new_predictions(predicted_group)
        @validation_errors = GroupMatchesValidator.new.validate(@group)

        save_predictions_for_group if @user and @validation_errors.empty?

        return [@group, @validation_errors]
        rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid
          [@group, @validation_errors]
      end

      # updates predictions for two group table positions by moving the prediction for
      # the given position according to the specified move operation (:up or :down).
      # The current prediction for the new position is swapped accordingly.
      def update(position_id, move_operation)
        predictable_item = @group_table_set.predictable_item(position_id)
        prediction = @user.prediction_for(predictable_item)
        current_value = prediction.predicted_value.to_i
        updated_value = move_operation.eql?(:up) ? (current_value - 1) : (current_value + 1)
        prediction_to_swap_value_with = @user.prediction_with_value(updated_value.to_s, @group_table_set)

        Core::Prediction.transaction do
          prediction.predicted_value = updated_value.to_s
          prediction_to_swap_value_with.predicted_value = current_value.to_s
          prediction.save!
          prediction_to_swap_value_with.save!
        end
      end

      private

      # builds the group results using the predictions stored in the db for the given user
      def group_from_existing_predictions
        match_predictions_by_item_id = @user.predictions.by_predictable_item(@group_matches_set)
        predictions_exists_for_user = (match_predictions_by_item_id and not match_predictions_by_item_id.empty?)

        if predictions_exists_for_user

          set_predicted_match_results do |item|
            prediction = match_predictions_by_item_id[item.id].first
            prediction.predicted_value
          end
          set_predicted_table_positions(@user.predictions.by_predictable_item(@group_table_set))
          GroupTableCalculator.new(@group).calculate(false)
        end
        [@group, predictions_exists_for_user]
      end

      # builds the group results using the provided request parameter hash
      def group_from_new_predictions(params)
        predicted_scores_by_match_id = params[:predicted_matches]

        if predicted_scores_by_match_id and predicted_scores_by_match_id.length > 0
          set_predicted_match_results do |item|
            prediction = predicted_scores_by_match_id[item.predictable_id.to_s]
            prediction[:home_team_score] + '-' + prediction[:away_team_score]
          end
          GroupTableCalculator.new(@group).calculate(true)
        end
        @group
      end

      # sets the predicted results for the group matches. The invoker must pass in a block
      # returning the predicted result of the match proxied by the yielded item.
      def set_predicted_match_results
        matches_by_id = @group.matches_by_id
        predicted_matches = []

        @group_matches_set.predictable_items.each do |item|
          match = matches_by_id[item.predictable_id]
          predicted_score = yield(item)
          match.set_individual_team_scores(predicted_score)
          predicted_matches << match
        end
        @group.matches = predicted_matches
      end

      # sets the predicted display order for the group table positions.
      def set_predicted_table_positions(table_position_predictions_by_item_id)
        predictable_items_by_predictable_id = @group_table_set.predictable_items.by_predictable_id

        @group.table_positions.each do |table_position|
          item = predictable_items_by_predictable_id[table_position.id].first
          table_position.display_order = table_position_predictions_by_item_id[item.id].first.predicted_value.to_i
        end
      end

      # saves the predicted group matches and table position for the current user.
      def save_predictions_for_group
        Core::Prediction.transaction do
          
          save_predictions(@group_matches_set, @group.matches_by_id) do |match|
            match.home_team_score + '-' + match.away_team_score
          end

          save_predictions(@group_table_set, table_positions_by_id) do |table_position|
            table_position.display_order.to_s
          end
        end
      end

      # saves predictions for the given set. second parameter must be a map to the actual
      # predictable instances (e.g., match or table position) keyed by the corresponding ids.
      # The invoker must pass in a block returning the value to be predicted on the predictable instance.
      def save_predictions(predictable_set, predictables_by_id)
        existing_predictions_by_item_id = @user.predictions.by_predictable_item(predictable_set)
        new_predictions = (existing_predictions_by_item_id.nil? or existing_predictions_by_item_id.empty?)

        predictable_set.predictable_items.each do |item|
          save_prediction(item, new_predictions, existing_predictions_by_item_id, predictables_by_id) do |predictable|
            yield(predictable)
          end
        end
      end

      # creates a new or updates an existing prediction for the given item. The invoker must pass in a
      # block returning the predicted value using the yielded predictable (e.g., match or table position instance)
      def save_prediction(item, new_prediction, existing_predictions_by_item_id, predictable_by_id)
        prediction = new_prediction ? Core::Prediction.new : existing_predictions_by_item_id[item.id].first
        prediction.core_user_id = @user.id if new_prediction
        prediction.configuration_predictable_item_id = item.id if new_prediction
        prediction.predicted_value = yield(predictable_by_id[item.predictable_id])
        prediction.save!
      end

      # returns a hash for the group table positions keyed by the corresponding ids
      def table_positions_by_id
        Hash[*(@group.table_positions).collect{|table_position| [table_position.id, table_position]}.flatten]
      end
    end
  end
end