module Isutrain
  class App < Sinatra::Base
    get '/api/train/seats' do
      date = Time.iso8601(params[:date]).getlocal

      halt_with_error 404, '予約可能期間外です' unless check_available_date(date)

      train = db.xquery(
        'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ?',
        date.strftime('%Y/%m/%d'),
        params[:train_class],
        params[:train_name],
      ).first

      halt_with_error 404, '列車が存在しません' if train.nil?

      from_name = params[:from]
      from_station = db.xquery(
        'SELECT * FROM `station_master` WHERE `name` = ?',
        from_name,
      ).first

      if from_station.nil?
        puts 'fromStation: no rows'
        halt_with_error 400, 'fromStation: no rows'
      end

      to_name = params[:to]
      to_station = db.xquery(
        'SELECT * FROM `station_master` WHERE `name` = ?',
        to_name,
      ).first

      if to_station.nil?
        puts 'toStation: no rows'
        halt_with_error 400, 'toStation: no rows'
      end

      usable_train_class_list = get_usable_train_class_list(from_station, to_station)
      unless usable_train_class_list.include?(train[:train_class])
        puts 'invalid train_class'
        halt_with_error 400, 'invalid train_class'
      end

      seat_list = db.xquery(
        'SELECT * FROM `seat_master` WHERE `train_class` = ? AND `car_number` = ? ORDER BY `seat_row`, `seat_column`',
        params[:train_class],
        params[:car_number],
      )

      seat_information_list = []

      seat_list.each do |seat|
        s = {
          row: seat[:seat_row],
          column: seat[:seat_column],
          class: seat[:seat_class],
          is_smoking_seat: seat[:is_smoking_seat],
          is_occupied: false
        }

        query = <<__EOF
          SELECT
            `s`.*
          FROM
            `seat_reservations` `s`,
            `reservations` `r`
          WHERE
            `r`.`date` = ? AND
            `r`.`train_class` = ? AND
            `r`.`train_name` = ? AND
            `car_number` = ? AND
            `seat_row` = ? AND
            `seat_column` = ?
__EOF

        seat_reservation_list = db.xquery(
          query,
          date.strftime('%Y/%m/%d'),
          seat[:train_class],
          params[:train_name],
          seat[:car_number],
          seat[:seat_row],
          seat[:seat_column],
        )

        seat_reservation_list.each do |seat_reservation|
          reservation = db.xquery(
            'SELECT * FROM `reservations` WHERE `reservation_id` = ?',
            seat_reservation[:reservation_id],
          ).first

          departure_station = db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            reservation[:departure],
          ).first

          arrival_station = db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            reservation[:arrival],
          ).first

          if train[:is_nobori]
            # 上り
            if to_station[:id] < arrival_station[:id] && from_station[:id] <= arrival_station[:id]
              # pass
            elsif to_station[:id] >= departure_station[:id] && from_station[:id] > departure_station[:id]
              # pass
            else
              s[:is_occupied] = true
            end
          else
            # 下り
            if from_station[:id] < departure_station[:id] && to_station[:id] <= departure_station[:id]
              # pass
            elsif from_station[:id] >= arrival_station[:id] && to_station[:id] > arrival_station[:id]
              # pass
            else
              s[:is_occupied] = true
            end
          end
        end

        seat_information_list << s
      end

      # 各号車の情報
      #simple_car_information_list = []
      #i = 1
      #loop do
      #  seat = db.xquery(
      #    'SELECT * FROM `seat_master` WHERE `train_class` = ? AND `car_number` = ? ORDER BY `seat_row`, `seat_column` LIMIT 1',
      #    params[:train_class],
      #    i,
      #  ).first

      #  break if seat.nil?

      #  simple_car_information = {
      #    car_number: i,
      #    seat_class: seat[:seat_class],
      #  }

      #  simple_car_information_list << simple_car_information

      #  i += 1
      #end
      items = db.xquery(
				%q(SELECT seat_class, car_number FROM `seat_master`
           WHERE `train_class` = ? AND `seat_row` = 1 AND `seat_column` = 'A'),
				params[:train_class],
			)
      simple_car_information_list = items.map{|item|
        {
          car_number: item[:car_number],
          seat_class: item[:seat_class],
        }
      }


      c = {
        date: date.strftime('%Y/%m/%d'),
        train_class: params[:train_class],
        train_name: params[:train_name],
        car_number: params[:car_number].to_i,
        seats: seat_information_list,
        cars: simple_car_information_list,
      }

      content_type :json
      c.to_json
    end
  end
end
