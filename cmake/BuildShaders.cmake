include("${CMAKE_CURRENT_LIST_DIR}/ShaderSources.cmake")

function(impeller_metal_shaders component name version shader_list)
  set(output_dir "${impeller_generated}/impeller/${component}")
  set(metal_dir "${output_dir}/mtl")
  set(metal_sources)
  set(reflection_sources)
  set(extra_flags ${ARGN})

  foreach(shader IN LISTS shader_list)
    set(input "${impeller_vendor}/${shader}")
    get_filename_component(filename "${input}" NAME)
    get_filename_component(directory "${input}" DIRECTORY)
    set(output "${output_dir}/${filename}")
    if(IMPELLER2D_REBUILD_SHADERS)
      set(metal "${output}.metal")
      list(APPEND metal_sources "${metal}")
      list(APPEND reflection_sources "${output}.cc")
      add_custom_command(
        OUTPUT "${metal}" "${output}.h" "${output}.cc"
        BYPRODUCTS "${output}.spirv" "${output}.json"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${output_dir}"
        COMMAND "${IMPELLER2D_IMPELLERC}"
          --metal-desktop "--metal-version=${version}"
          --define=IMPELLER_TARGET_METAL --define=IMPELLER_TARGET_METAL_DESKTOP
          ${extra_flags}
          "--input=${input}" "--include=${directory}"
          "--include=${impeller_vendor}/impeller/compiler/shader_lib"
          "--sl=${metal}" "--spirv=${output}.spirv"
          "--reflection-json=${output}.json"
          "--reflection-header=${output}.h" "--reflection-cc=${output}.cc"
          "--depfile=${output}.d"
        DEPENDS "${input}" "${IMPELLER2D_IMPELLERC}"
        DEPFILE "${output}.d"
        VERBATIM
      )
    else()
      list(APPEND reflection_sources
        "${impeller_vendor}/generated/impeller/${component}/${filename}.cc")
    endif()
  endforeach()

  set(library "${metal_dir}/${name}.metallib")
  set(header "${metal_dir}/${name}_shaders.h")
  set(source "${metal_dir}/${name}_shaders.cc")
  if(IMPELLER2D_REBUILD_SHADERS)
    add_custom_command(
      OUTPUT "${library}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${metal_dir}"
      COMMAND "${IMPELLER2D_METAL}"
        "-fmodules-cache-path=${impeller_generated}/metal-cache"
        -isysroot "${impeller_metal_sdk}" "-std=macos-metal${version}"
        "-mmacosx-version-min=${impeller_metal_deployment}"
        -Wno-unused-variable -Oz -ffast-math -o "${library}" ${metal_sources}
      DEPENDS ${metal_sources}
      VERBATIM
    )
  else()
    set(library "${impeller_vendor}/generated/impeller/${component}/mtl/${name}.metallib")
  endif()
  add_custom_command(
    OUTPUT "${header}" "${source}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${metal_dir}"
    COMMAND "${Python3_EXECUTABLE}" "${impeller_cmake}/EmbedBinary.py"
      "${library}" "${header}" "${source}" "impeller_${name}_shaders"
    DEPENDS "${library}" "${impeller_cmake}/EmbedBinary.py"
    VERBATIM
  )
  set(impeller_generated_sources ${impeller_generated_sources}
    ${reflection_sources} "${header}" "${source}" PARENT_SCOPE)
endfunction()

impeller_metal_shaders(entity entity 1.2 "${impeller_entity_shaders}"
  --use-half-textures)
impeller_metal_shaders(entity modern 1.2 "${impeller_modern_entity_shaders}")
impeller_metal_shaders(entity framebuffer_blend 2.3
  "${impeller_framebuffer_blend_entity_shaders}")
impeller_metal_shaders(renderer compute 2.1 "${impeller_compute_shaders}")

set(runtime_dir "${impeller_vendor}/impeller/runtime_stage")
set(runtime_out "${impeller_generated}/impeller/runtime_stage")
set(runtime_headers
  "${runtime_out}/runtime_stage_flatbuffers.h"
  "${runtime_out}/runtime_stage_types_flatbuffers.h"
)
add_custom_command(
  OUTPUT ${runtime_headers}
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${runtime_out}"
  COMMAND "${IMPELLER2D_FLATC}" --cpp --scoped-enums
    --filename-suffix _flatbuffers -o "${runtime_out}"
    "${runtime_dir}/runtime_stage_types.fbs" "${runtime_dir}/runtime_stage.fbs"
  DEPENDS "${IMPELLER2D_FLATC}"
    "${runtime_dir}/runtime_stage_types.fbs" "${runtime_dir}/runtime_stage.fbs"
  VERBATIM
)
list(APPEND impeller_generated_sources ${runtime_headers})
