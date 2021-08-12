load("//spm/internal/modulemap_parser:declarations.bzl", dts = "declaration_types")
load("//spm/internal/modulemap_parser:parser.bzl", "parser")
load(":package_descriptions.bzl", "module_types", pds = "package_descriptions")
load(":packages.bzl", "packages")
load(":references.bzl", ref_types = "reference_types", refs = "references")
load(":spm_common.bzl", "spm_common")
load("@bazel_skylib//lib:paths.bzl", "paths")

# MARK: - File Listing Functions

def _list_files_under(repository_ctx, path):
    """Retrieves the list of files under the specified path.

    This function returns paths for all of the files under the specified path.

    Args:
        repository_ctx: A `repository_ctx` instance.
        path: A path `string` value.

    Returns:
        A `list` of path `string` values.
    """
    exec_result = repository_ctx.execute(
        ["find", path],
        quiet = True,
    )
    if exec_result.return_code != 0:
        fail("Failed to list files in %s. stderr:\n%s" % (path, exec_result.stderr))
    paths = exec_result.stdout.splitlines()
    return paths

def _list_directories_under(repository_ctx, path, max_depth = None):
    """Retrieves the list of directories under the specified path.

    Args:
        repository_ctx: A `repository_ctx` instance.
        path: A path `string` value.
        max_depth: Optional. The depth for the directory search.

    Returns:
        A `list` of path `string` values.
    """
    find_args = ["find", path, "-type", "d"]
    if max_depth != None:
        find_args.extend(["-maxdepth", "%d" % (max_depth)])
    exec_result = repository_ctx.execute(find_args, quiet = True)
    if exec_result.return_code != 0:
        fail("Failed to list directories under %s. stderr:\n%s" % (path, exec_result.stderr))
    paths = exec_result.stdout.splitlines()
    return [p for p in paths if p != path]

# MARK: - Module Declaration Functions

_spm_swift_module_tpl = """
spm_swift_module(
    name = "%s",
    packages = "@%s//:build",
    deps = [
%s
    ],
    visibility = ["//visibility:public"],
)
"""

_spm_clang_module_tpl = """
spm_clang_module(
    name = "%s",
    packages = "@%s//:build",
    deps = [
%s
    ],
    visibility = ["//visibility:public"],
)
"""

_bazel_pkg_hdr = """
load("@cgrindel_rules_spm//spm:spm.bzl", "spm_swift_module", "spm_clang_module")
"""

def _create_deps_str(pkg_name, target_deps):
    """Create deps list string suitable for injection into a module template.

    Args:
        pkg_name: The name of the Swift package as a `string`.
        target_deps: A `list` of the target's dependencies as target
                     references.

    Returns:
        A `string` value.
    """
    target_labels = []
    for target_ref in target_deps:
        rtype, pname, tname = refs.split(target_ref)
        if pname == pkg_name:
            target_labels.append(":%s" % (tname))
        else:
            target_labels.append("//%s:%s" % (pname, tname))

    deps = ["        \"%s\"," % (label) for label in target_labels]
    return "\n".join(deps)

def _create_spm_swift_module_decl(repository_ctx, pkg_name, target, target_deps):
    """Returns the spm_swift_module declaration for this Swift target.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkg_name: The name of the Swift package as a `string`.
        target: A target `dict` from a package description JSON.
        target_deps: A `list` of the target's dependencies as target
                     references.

    Returns:
        A `string` representing an `spm_swift_module` declaration.
    """
    module_name = target["name"]
    deps_str = _create_deps_str(pkg_name, target_deps)
    return _spm_swift_module_tpl % (module_name, repository_ctx.attr.name, deps_str)

def _create_spm_clang_module_decl(repository_ctx, pkg_name, target, target_deps):
    """Returns the spm_clang_module declaration for this clang target.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkg_name: The name of the Swift package as a `string`.
        target: A target `dict` from a package description JSON.
        target_deps: A `list` of the target's dependencies as target
                     references.

    Returns:
        A `string` representing an `spm_clang_module` declaration.
    """
    module_name = target["name"]
    deps_str = _create_deps_str(pkg_name, target_deps)
    return _spm_clang_module_tpl % (module_name, repository_ctx.attr.name, deps_str)

def _generate_bazel_pkg(repository_ctx, pkg_desc, dep_target_refs_dict, clang_hdrs_dict):
    """Generate a Bazel package for the specified Swift package.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkg_desc: A package description `dict`.
        dep_target_refs_dict: A `dict` of target refs and their dependenceis.
        clang_hdrs_dict: A `dict` where the values are a `list` of clang
                         public header path `string` values and the keys are
                         a `string` created by
                         `spm_common.create_clang_hdrs_key()`.
    """
    pkg_name = pkg_desc["name"]
    bld_path = "%s/BUILD.bazel" % (pkg_name)

    # Collect the target refs for the specified package
    target_refs = [tr for tr in dep_target_refs_dict if refs.is_target_ref(tr, for_pkg = pkg_name)]

    module_decls = []
    for target_ref in target_refs:
        target_deps = dep_target_refs_dict[target_ref]
        rtype, pname, target_name = refs.split(target_ref)
        target = pds.get_target(pkg_desc, target_name)
        if pds.is_clang_target(target):
            module_decls.append(_create_spm_clang_module_decl(
                repository_ctx,
                pkg_name,
                target,
                target_deps,
            ))
        else:
            module_decls.append(_create_spm_swift_module_decl(
                repository_ctx,
                pkg_name,
                target,
                target_deps,
            ))

    bld_content = _bazel_pkg_hdr + "".join(module_decls)
    repository_ctx.file(bld_path, content = bld_content, executable = False)

# MARK: - Clang Custom Headers Functions

def _is_modulemap_path(path):
    """Determines whether the specified path is to a public `module.modulemap` 
    file.

    Args:
        path: A path `string`.

    Returns:
        A `bool` indicating whether the path is a public `module.modulemap`
        file.
    """
    basename = paths.basename(path)
    dirname = paths.basename(paths.dirname(path))
    return dirname == "include" and basename == "module.modulemap"

def _get_hdr_paths_from_modulemap(repository_ctx, module_paths, modulemap_path):
    """Retrieves the list of headers declared in the specified modulemap file.

    Args:
        repository_ctx: A `repository_ctx` instance.
        module_paths: A `list` of path `string` values.
        modulemap_path: A path `string` to the `module.modulemap` file.

    Returns:
        A `list` of path `string` values.
    """
    modulemap_str = repository_ctx.read(modulemap_path)
    decls, err = parser.parse(modulemap_str)
    if err != None:
        fail("Errors parsing the %s. %s" % (modulemap_path, err))

    module_decls = [d for d in decls if d.decl_type == dts.module]
    module_decls_len = len(module_decls)
    if module_decls_len == 0:
        fail("No module declarations were found in %s." % (modulemap_path))
    if module_decls_len > 1:
        fail("Expected a single module definition but found %s." % (module_decls_len))
    module_decl = module_decls[0]

    modulemap_dirname = paths.dirname(modulemap_path)
    hdrs = []
    for cdecl in module_decl.members:
        if cdecl.decl_type == dts.single_header and not cdecl.private and not cdecl.textual:
            # Resolve the path relative to the modulemap
            hdr_path = paths.join(modulemap_dirname, cdecl.path)
            normalized_hdr_path = paths.normalize(hdr_path)
            hdrs.append(normalized_hdr_path)

    return hdrs

def _is_include_hdr_path(path):
    """Determines whether the path is a public header.

    Args:
        path: A path `string` value.

    Returns:
        A `bool` indicating whether the path is a public header.
    """
    root, ext = paths.split_extension(path)
    dirname = paths.basename(paths.dirname(path))
    return dirname == "include" and ext == ".h"

def _get_clang_hdrs_for_target(repository_ctx, target, pkg_root_path = ""):
    """Returns a list of the public headers for the clang target.

    Args:
        repository_ctx: A `repository_ctx` instance.
        target: A target `dict` from the package description JSON.
        pkg_root_path: A path `string` specifying the location of the package
                       which defines the target.

    Returns:
        A `list` of path `string` values.
    """
    src_path = paths.join(pkg_root_path, target["path"])
    module_paths = _list_files_under(repository_ctx, src_path)

    modulemap_paths = [p for p in module_paths if _is_modulemap_path(p)]
    modulemap_paths_len = len(modulemap_paths)
    if modulemap_paths_len > 1:
        fail("Found more than one module.modulemap file. %" % (modulemap_paths))

    # If a modulemap was provided, read it for header info.
    # Otherwise, use all of the header files under the "include" directory.
    if modulemap_paths_len == 1:
        return _get_hdr_paths_from_modulemap(
            repository_ctx,
            module_paths,
            modulemap_paths[0],
        )
    return [p for p in module_paths if _is_include_hdr_path(p)]

# MARK: - Root BUILD.bazel Generation

def _create_hdrs_str(hdr_paths):
    """Creates a headers string suitable for injection into a BUILD.bazel 
    template.

    Args:
        hdr_paths: A `list` of path `string` values.

    Returns:
        A `string` value suitable for injection into the `clang_module_headers`
        entry.
    """
    hdrs = ["        \"%s\"," % (p) for p in hdr_paths]
    return "\n".join(hdrs)

def _create_clang_module_headers_entry(target_name, hdr_paths):
    """Creates a `clang_module_headers` entry string.

    Args:
        target_name: The target name as a `string`.
        hdr_paths: A `list` of path `string` values.

    Returns:
        A `string` suitable for injection into a BUILD.bazel template.
    """
    entry_tpl = """\
        "%s": [
    %s
        ],
    """
    hdrs_str = _create_hdrs_str(hdr_paths)
    return entry_tpl % (target_name, hdrs_str)

def _create_clang_module_headers(hdrs_dict):
    """Creates a collection of `clang_module_headers` entries.

    Args:
        hdrs_dict: A `dict` where the values are a `list` of path `string`
                   values and the keys are target name `string` values.

    Returns:
        A `string` suitable for injection into a BUILD.bazel template.
    """
    entries = [_create_clang_module_headers_entry(k, hdrs_dict[k]) for k in hdrs_dict]
    return "\n".join(entries)

def _generate_root_bld_file(repository_ctx, pkg_descs_dict, clang_hdrs_dict, pkgs):
    """Generates a BUILD.bazel file for the directory from which all external
    SPM packages will be made available.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkg_descs_dict: A `dict` of package descriptions indexed by package name.
        clang_hdrs_dict: A `dict` where the values are a `list` of clang
                         public header path `string` values and the keys are
                         a `string` created by
                         `spm_common.create_clang_hdrs_key()`.
        pkgs: A `list` of package declarations as created by `packages.create()`.
    """
    substitutions = {
        "{spm_repos_name}": repository_ctx.attr.name,
        "{pkg_descs_json}": json.encode_indent(pkg_descs_dict, indent = "  "),
        "{clang_module_headers}": _create_clang_module_headers(clang_hdrs_dict),
        "{dependencies_json}": json.encode_indent(pkgs),
    }
    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._root_build_tpl,
        substitutions = substitutions,
        executable = False,
    )

# MARK: - Package.swift Generation

_package_tpl = """\
.package(name: "%s", url: "%s", from: "%s")\
"""

_target_dep_tpl = """\
.product(name: "%s", package: "%s")\
"""

_platforms_tpl = """\
  platforms: [
%s
  ],
"""

def _generate_package_swift_file(repository_ctx, pkgs):
    """Generate a Package.swift file which will be used to fetch and build the 
    external SPM packages.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkgs: A `list` of package declarations as created by `packages.create()`.
    """
    swift_platforms = ""
    if len(repository_ctx.attr.platforms) > 0:
        swift_platforms = _platforms_tpl % (
            ",\n".join(["    %s" % (p) for p in repository_ctx.attr.platforms])
        )

    pkg_deps = [_package_tpl % (pkg.name, pkg.url, pkg.from_version) for pkg in pkgs]
    target_deps = [_target_dep_tpl % (pname, pkg.name) for pkg in pkgs for pname in pkg.products]
    substitutions = {
        "{swift_tools_version}": repository_ctx.attr.swift_version,
        "{swift_platforms}": swift_platforms,
        "{package_dependencies}": ",\n".join(["    %s" % (d) for d in pkg_deps]),
        "{target_dependencies}": ",\n".join(["      %s" % (d) for d in target_deps]),
    }
    repository_ctx.template(
        "Package.swift",
        repository_ctx.attr._package_swift_tpl,
        substitutions = substitutions,
        executable = False,
    )

# MARK: - Rule Implementation

def _configure_spm_repository(repository_ctx, pkgs):
    """Fetches the external SPM packages, prepares them for a future build step 
    and defines Bazel targets.

    Args:
        repository_ctx: A `repository_ctx` instance.
        pkgs: A `list` of package declarations as created by `packages.create()`.
    """

    # Resolve/fetch the dependencies.
    resolve_result = repository_ctx.execute(
        ["swift", "package", "resolve", "--build-path", spm_common.build_dirname],
    )
    if resolve_result.return_code != 0:
        fail("Resolution of SPM packages for %s failed.\n%s" % (
            repository_ctx.attr.name,
            resolve_result.stderr,
        ))

    pkg_descs_dict = dict()
    clang_hdrs_dict = dict()

    root_pkg_desc = pds.get(repository_ctx)
    pkg_descs_dict[pds.root_pkg_name] = root_pkg_desc

    fetched_pkg_paths = _list_directories_under(
        repository_ctx,
        spm_common.checkouts_path,
        max_depth = 1,
    )
    for pkg_path in fetched_pkg_paths:
        dep_pkg_desc = pds.get(repository_ctx, working_directory = pkg_path)
        dep_name = dep_pkg_desc["name"]
        pkg_descs_dict[dep_name] = dep_pkg_desc

        # Look for custom header declarations in the clang targets
        clang_targets = [t for t in pds.library_targets(dep_pkg_desc) if pds.is_clang_target(t)]
        for clang_target in clang_targets:
            clang_hdr_paths = _get_clang_hdrs_for_target(
                repository_ctx,
                clang_target,
                pkg_root_path = paths.join(spm_common.checkouts_path, dep_name),
            )
            clang_hdrs_key = spm_common.create_clang_hdrs_key(
                dep_name,
                clang_target["name"],
            )
            clang_hdrs_dict[clang_hdrs_key] = clang_hdr_paths

    # Create Bazel targets for every declared product and any of its transitive
    # dependencies
    declared_product_refs = packages.get_product_refs(pkgs)
    dep_target_refs_dict = pds.transitive_dependencies(pkg_descs_dict, declared_product_refs)
    for pkg_name in pkg_descs_dict:
        _generate_bazel_pkg(
            repository_ctx,
            pkg_descs_dict[pkg_name],
            dep_target_refs_dict,
            clang_hdrs_dict,
        )

    # Write BUILD.bazel file.
    _generate_root_bld_file(repository_ctx, pkg_descs_dict, clang_hdrs_dict, pkgs)

def _spm_repositories_impl(repository_ctx):
    pkgs = [packages.from_json(j) for j in repository_ctx.attr.dependencies]

    # Generate Package.swift
    _generate_package_swift_file(repository_ctx, pkgs)

    # Create barebones source files
    repository_ctx.file(
        "Sources/Placeholder/Placeholder.swift",
        content = """
        // Placeholder code
        """,
        executable = False,
    )

    # Configure the SPM package
    _configure_spm_repository(repository_ctx, pkgs)

spm_repositories = repository_rule(
    implementation = _spm_repositories_impl,
    attrs = {
        "dependencies": attr.string_list(
            mandatory = True,
            doc = "List of JSON strings specifying the SPM packages to load.",
        ),
        "swift_version": attr.string(
            default = "5.3",
            doc = """\
            The version of Swift that will be declared in the placeholder/uber Swift package.\
            """,
        ),
        "platforms": attr.string_list(
            doc = """\
            The platforms to declare in the placeholder/uber Swift package. \
            (e.g. .macOS(.v10_15))\
            """,
        ),
        "_package_swift_tpl": attr.label(
            default = "//spm/internal:Package.swift.tpl",
        ),
        "_root_build_tpl": attr.label(
            default = "//spm/internal:root.BUILD.bazel.tpl",
        ),
    },
    doc = """\
    Used to fetch and prepare external Swift package manager packages for the build.
    """,
)

spm_pkg = packages.pkg_json