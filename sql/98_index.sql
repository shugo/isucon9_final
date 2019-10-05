CREATE INDEX index_search_train_timetable_master ON train_timetable_master(date, train_class, train_name, station);

CREATE INDEX index_station_master_name station_master(name);
CREATE INDEX index_station_master_is_stop_express station_master(is_stop_express);
CREATE INDEX index_station_master_is_stop_semi_express station_master(is_stop_semi_express);
CREATE INDEX index_station_master_is_stop_local station_master(is_stop_local);

CREATE INDEX index_seat_master_train_class seat_master(train_class);
CREATE INDEX index_seat_master_car_number seat_master(car_number);
CREATE INDEX index_seat_master_seat_column seat_master(seat_column);
CREATE INDEX index_seat_master_seat_row seat_master(seat_row);
CREATE INDEX index_seat_master_seat_class seat_master(seat_class);
CREATE INDEX index_seat_master_is_smoking_seat seat_master(is_smoking_seat);

CREATE INDEX index_train_master_date train_master(date);
CREATE INDEX index_train_master_departure_at train_master(departure_at);
CREATE INDEX index_train_master_train_class train_master(train_class);
CREATE INDEX index_train_master_train_name train_master(train_name);
CREATE INDEX index_train_master_start_station train_master(start_station);
CREATE INDEX index_train_master_last_station train_master(last_station);
CREATE INDEX index_train_master_is_nobori train_master(is_nobori);

CREATE INDEX index_reservations_user_id reservations(user_id);

CREATE INDEX index_seat_reservations_reservation_id seat_reservations(reservation_id);
CREATE INDEX index_seat_reservations_car_number seat_reservations(car_number);
