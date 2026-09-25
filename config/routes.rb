Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Readiness: can this instance actually scrape? Checks curl-impersonate and
  # FlareSolverr. Kept separate from /up so a down browser never blocks a deploy.
  get "ready" => "readiness#show"

  # API routes are defined under the api/v1 namespace, one explicit line per
  # supported site. An unknown site has no route and so returns 404.
  namespace :api do
    namespace :v1 do
      get "nissei/search", to: "nissei#search"
      get "nissei/home", to: "nissei#home"
      get "booking/search", to: "booking#search"
    end
  end
end
