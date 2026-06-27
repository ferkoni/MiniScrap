Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API routes are defined under the api/v1 namespace per site, e.g.
  #   namespace(:api) { namespace(:v1) { get "nissei/search", to: "nissei#search" } }
end
