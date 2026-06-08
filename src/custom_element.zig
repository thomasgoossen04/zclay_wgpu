const zvec = @import("zvec");

pub const CustomElementType = enum {
    vector_graphic,
};

pub const CustomElementData = union(CustomElementType) {
    vector_graphic: zvec.VecGraphic,
};
