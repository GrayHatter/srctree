server: ?Server,
owner: ?Owner,
repos: ?Repos,
agent: ?Agent,
notifications: ?Notifications,
git: ?Git,
ci: ?Ci,

const Config = @This();

pub var global: Config = .empty;

pub const empty: Config = .{
    .server = null,
    .owner = null,
    .repos = null,
    .agent = null,
    .notifications = null,
    .git = .default,
    .ci = null,
};

pub const Server = struct {
    block_scripted_traffic: bool = true,
    remove_on_start: bool = false,
    sock: ?[]const u8,
};

pub const Owner = struct {
    email: ?[]const u8,
    tz: ?[]const u8,
};

pub const Repos = struct {
    /// Directory of public repos
    dir: ?[]const u8,
    /// Directory of private repos
    private_dir: ?[]const u8,
    /// List of repos that should be hidden
    private_repos: ?[]const u8,
    unlisted_repos: ?[]const u8,
};

pub const Agent = struct {
    enabled: bool = false,
    skip_repos: ?[]const u8 = null,
    upstream_push: bool = false,
    upstream_pull: bool = false,
    downstream_push: bool = false,
    downstream_pull: bool = false,
};

pub const Notifications = struct {
    enabled: bool = false,
    sender: ?[]const u8 = null,
    receiver: ?[]const u8 = null,
};

pub const Git = struct {
    push_enabled: bool = false,
    pull_enabled: bool = true,
    auto_create_enabled: bool = false,
    hooks_disabled: bool = false,

    pub const default: Git = .{};
};

pub const Ci = struct {
    enabled: ?bool,
    working_path: ?[]const u8,
    cache_enabled: ?bool,

    pub const default: Ci = .{
        .enabled = false,
        .working_path = "working",
        .cache_enabled = false,
    };
};
