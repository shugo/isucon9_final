module Isutrain
  module Utils
    TRAIN_CLASS_MAP = {
      express: '最速',
      semi_express: '中間',
      local: '遅いやつ',
    }
    AVAILABLE_DAYS = 366

    def check_available_date(date)
      t = Time.new(2020, 1, 1, 0, 0, 0, '+09:00')
      t += 60 * 60 * 24 * AVAILABLE_DAYS

      date < t
    end

    def get_usable_train_class_list(from_station, to_station)
      usable = TRAIN_CLASS_MAP.dup

      usable.delete(:express) unless from_station[:is_stop_express]
      usable.delete(:semi_express) unless from_station[:is_stop_semi_express]
      usable.delete(:local) unless from_station[:is_stop_local]

      usable.delete(:express) unless to_station[:is_stop_express]
      usable.delete(:semi_express) unless to_station[:is_stop_semi_express]
      usable.delete(:local) unless to_station[:is_stop_local]

      usable.values
    end

    def get_available_seats(train, from_station, to_station, seat_class, is_smoking_seat)
      # 指定種別の空き座席を返す

      # 全ての座席件数を取得する
      max_seat_count = seat_counts[[train[:train_class], seat_class, is_smoking_seat]] || 0

      query = <<__EOF
        SELECT
          COUNT(`sr`.`reservation_id`) AS seat_count
        FROM
          `seat_reservations` `sr`,
          `reservations` `r`,
          `seat_master` `s`,
          `station_master` `std`,
          `station_master` `sta`
        WHERE
          `r`.`date` = ? AND
          `r`.`reservation_id` = `sr`.`reservation_id` AND
          `s`.`seat_class` = ? AND
          `s`.`is_smoking_seat` = ? AND
          `s`.`train_class` = `r`.`train_class` AND
          `s`.`car_number` = `sr`.`car_number` AND
          `s`.`seat_column` = `sr`.`seat_column` AND
          `s`.`seat_row` = `sr`.`seat_row` AND
          `std`.`name` = `r`.`departure` AND
          `sta`.`name` = `r`.`arrival`
__EOF

      if train[:is_nobori]
        query += 'AND ((`sta`.`id` < ? AND ? <= `std`.`id`) OR (`sta`.`id` < ? AND ? <= `std`.`id`) OR (? < `sta`.`id` AND `std`.`id` < ?))'
      else
        query += 'AND ((`std`.`id` <= ? AND ? < `sta`.`id`) OR (`std`.`id` <= ? AND ? < `sta`.`id`) OR (`sta`.`id` < ? AND ? < `std`.`id`))'
      end

      reserved_seat_count = db.xquery(
        query,
        train[:date],
        seat_class,
        is_smoking_seat,
        from_station[:id],
        from_station[:id],
        to_station[:id],
        to_station[:id],
        from_station[:id],
        to_station[:id],
      ).first[:seat_count]

      max_seat_count - reserved_seat_count
    end
  end
end
