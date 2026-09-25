module Api
  module V1
    # Booking.com search results. Unlike nissei's free-text `q`, a Booking
    # search is several typed params, validated here (400 before any fetch)
    # and rebuilt into a clean URL: nothing the client sends is forwarded
    # as-is, and none of Booking's tracking/session params (sid, aid, label,
    # …) are ever added.
    #
    # Booking sits behind AWS WAF, hence the extra detector.
    class BookingController < ScrapeController
      scrapes "booking",
        base_url: "https://www.booking.com/",
        profile: :chrome146, # closest to FlareSolverr's Chromium (see FlareSolverrSolver)
        parser: Scraper::Booking::SearchParser.new

      # Prices follow the egress IP's location unless a currency is pinned.
      CURRENCY = "USD".freeze
      # Destination kinds Booking's own search uses; only "city" is verified.
      DEST_TYPES = %w[city region district country landmark airport hotel].freeze
      MAX_SS_LENGTH = 100
      ADULTS = 1..30
      ROOMS = 1..30
      CHILDREN = 0..10
      MAX_OFFSET = 1000

      # GET /api/v1/booking/search?dest_id=-910015&dest_type=city&checkin=…&checkout=…&adults=2
      # GET /api/v1/booking/search?ss=Asuncion&checkin=…&checkout=…&offset=25
      def search
        query = search_query
        scrape(
          "searchresults.es.html?#{URI.encode_www_form(query)}",
          parser: Scraper::Booking::SearchParser.new(offset: query[:offset])
        )
      end

      private

      def detectors = super + [Scraper::AwsWafDetector.new]

      # Validated params, in Booking's names and order. Collects every error
      # before raising, so a client sees all of them at once.
      def search_query
        errors = {}
        destination = destination(errors)
        checkin = date(:checkin, errors)
        checkout = date(:checkout, errors)
        if checkin && checkout
          errors[:checkout] = "must be after checkin" unless checkout > checkin
          errors[:checkin] = "must not be in the past" if checkin < Date.current
        end
        adults = integer(:adults, ADULTS, errors, default: 2)
        rooms = integer(:rooms, ROOMS, errors, default: 1)
        children = integer(:children, CHILDREN, errors, default: 0)
        offset = integer(:offset, 0..MAX_OFFSET, errors, default: 0)
        raise InvalidParams, errors if errors.any?

        {
          **destination,
          checkin: checkin.iso8601, checkout: checkout.iso8601,
          group_adults: adults, no_rooms: rooms, group_children: children,
          offset: offset, selected_currency: CURRENCY
        }
      end

      # dest_id + dest_type when given (precise), else free-text ss. With both,
      # ss is dropped so Booking can't reinterpret the destination.
      def destination(errors)
        if params[:dest_id].present?
          errors[:dest_id] = "must be an integer" unless params[:dest_id].to_s.match?(/\A-?\d+\z/)
          errors[:dest_type] = "must be one of #{DEST_TYPES.join(", ")}" unless DEST_TYPES.include?(params[:dest_type].to_s)
          { dest_id: params[:dest_id].to_s, dest_type: params[:dest_type].to_s }
        elsif params[:ss].to_s.strip.present?
          ss = params[:ss].to_s.strip
          errors[:ss] = "must be at most #{MAX_SS_LENGTH} characters" if ss.length > MAX_SS_LENGTH
          { ss: ss }
        else
          errors[:destination] = "give dest_id with dest_type, or ss"
          {}
        end
      end

      def date(name, errors)
        Date.iso8601(params.require(name).to_s)
      rescue ActionController::ParameterMissing
        errors[name] = "is required"
        nil
      rescue Date::Error
        errors[name] = "must be an ISO date (YYYY-MM-DD)"
        nil
      end

      def integer(name, range, errors, default:)
        return default if params[name].blank?

        value = Integer(params[name].to_s, 10)
        return value if range.cover?(value)

        errors[name] = "must be between #{range.min} and #{range.max}"
        nil
      rescue ArgumentError
        errors[name] = "must be an integer"
        nil
      end
    end
  end
end
