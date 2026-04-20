#include "mesher_native.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

MesherNative::MesherNative() {}

MesherNative::~MesherNative() {}

String MesherNative::ping() const {
	return String("native mesher stub alive");
}

void MesherNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ping"), &MesherNative::ping);
}
