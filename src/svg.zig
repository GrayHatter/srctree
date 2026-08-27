pub const Icon = enum {
    comment,
    comment_new,
    lock,
    tag,
    trash,
    people,
    person,
    eye,
    eye_closed,

    pub const Style = struct {
        w: usize = 20,
        h: usize = 16,
        color: []const u8 = "#ffffff",
    };

    pub fn slice(i: Icon, comptime style: Style) [:0]const u8 {
        const prefix = std.fmt.comptimePrint(
            "<svg width={}px height={}px viewBox=\"0 0 22 22\" fill=\"{s}\">",
            .{ style.w, style.h, style.color },
        );
        return switch (i) {
            .comment => prefix ++
                \\<path d="M2 2H20V3H21V17H20V18H12V19H11V20H10V21H6V18H2V17H1V3H2V2M3 4V16H8V19H9V18H10V17H11V16H19V4H3Z" /></svg>
            ,
            .comment_new => prefix ++
                \\<path d="M2 2H20V3H21V17H20V18H12V19H11V20H10V21H6V18H2V17H1V3H2V2M3 4V16H8V19H9V18H10V17H11V16H19V4H3M5 7H17V9H5V7M5 11H15V13H5V11Z" /></svg>
            ,
            .lock => prefix ++
                \\<path d="M10 12H12V13H13V15H12V16H10V15H9V13H10V12M8 2H14V3H15V4H16V8H17V9H18V19H17V20H5V19H4V9H5V8H6V4H7V3H8V2M9 4V5H8V8H14V5H13V4H9M16 10H6V18H16V10Z" />
            ,
            .trash => prefix ++
                \\<path d="M10 7V16H8V7H10M12 7H14V16H12V7M8 2H14V3H19V5H18V19H17V20H5V19H4V5H3V3H8V2M6 5V18H16V5H6Z" /></svg>
            ,
            .tag => prefix ++
                \\<path d="M1 2H2V1H11V2H12V3H13V4H14V5H15V6H16V7H17V8H18V9H19V10H20V11H21V13H20V14H19V15H18V16H17V17H16V18H15V19H14V20H13V21H11V20H10V19H9V18H8V17H7V16H6V15H5V14H4V13H3V12H2V11H1V2M3 10H4V11H5V12H6V13H7V14H8V15H9V16H10V17H11V18H13V17H14V16H15V15H16V14H17V13H18V11H17V10H16V9H15V8H14V7H13V6H12V5H11V4H10V3H3V10M14 11H15V13H14V12H13V11H12V10H11V9H10V7H11V8H12V9H13V10H14V11M10 12H11V13H12V15H11V14H10V13H9V12H8V10H9V11H10V12M5 4H7V5H8V7H7V8H5V7H4V5H5V4Z" /></svg>
            ,
            .eye => prefix ++
                \\<path d="M8 6h8v2H8V6zm-4 4V8h4v2H4zm-2 2v-2h2v2H2zm0 2v-2H0v2h2zm2 2H2v-2h2v2zm4 2H4v-2h4v2zm8 0v2H8v-2h8zm4-2v2h-4v-2h4zm2-2v2h-2v-2h2zm0-2h2v2h-2v-2zm-2-2h2v2h-2v-2zm0 0V8h-4v2h4zm-10 1h4v4h-4v-4z" fill="#ffffff" /></svg>
            ,
            .eye_closed => prefix ++
                \\<path d="M0 7h2v2H0V7zm4 4H2V9h2v2zm4 2v-2H4v2H2v2h2v-2h4zm8 0H8v2H6v2h2v-2h8v2h2v-2h-2v-2zm4-2h-4v2h4v2h2v-2h-2v-2zm2-2v2h-2V9h2zm0 0V7h2v2h-2z" fill="#ffffff" /></svg>
            ,
            .people => prefix ++
                \\<path d="M15 2H9v2H7v6h2V4h6V2zm0 8H9v2h6v-2zm0-6h2v6h-2V4zM4 16h2v-2h12v2H6v4h12v-4h2v6H4v-6z" fill="#000000" /></svg>
            ,
            .person => prefix ++
                \\<path d="M15 2H9v2H7v6h2V4h6V2zm0 8H9v2h6v-2zm0-6h2v6h-2V4zM4 16h2v-2h12v2H6v4h12v-4h2v6H4v-6z" fill="#000000" /></svg>
            ,
        };
    }
};

const std = @import("std");
