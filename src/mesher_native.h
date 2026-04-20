#ifndef MESHER_NATIVE_H
#define MESHER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Scaffold class — proves the GDExtension toolchain (godot-cpp submodule,
// SConstruct, gdextension manifest, class registration, method binding)
// works end to end. The actual mesh_chunk port lands in the follow-up
// commit; keeping the scaffold empty here means a compile or load failure
// is immediately visible without touching any gameplay code path.
class MesherNative : public RefCounted {
	GDCLASS(MesherNative, RefCounted);

public:
	MesherNative();
	~MesherNative();

	String ping() const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
