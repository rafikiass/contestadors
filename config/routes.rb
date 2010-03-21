ActionController::Routing::Routes.draw do |map|
  map.resource :account, :controller => "users"
  map.resources :users
  map.resource :user_session
  map.resources :predictions,
    :path_prefix => '/:contest/:aggregate_root_type/:aggregate_root_id'
  map.championship_predictions "championship/group/A",
    :controller => "predictions", :action => "new",
    :contest => "championship", :aggregate_root_type => "group", :aggregate_root_id => "A"
  map.root :controller => "user_sessions", :action => "new"
end
