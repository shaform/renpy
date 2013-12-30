from cpython.ref cimport PyObject, Py_XDECREF
from libc.string cimport memset
from libc.stdlib cimport calloc, free

import renpy

include "styleconstants.pxi"

################################################################################
# Property Functions
################################################################################

# A class that wraps a pointer to a property function.
cdef class PropertyFunctionWrapper:
    cdef property_function function

# A dictionary that maps the name of a property function into a
# PropertyFunctionWrapper.
cdef dict property_functions = { }

cdef void register_property_function(name, property_function function):
    """
    Registers `function` to be the property function called for the
    property `name`.
    """

    cdef PropertyFunctionWrapper pfw

    pfw = PropertyFunctionWrapper()
    pfw.function = function
    property_functions[name] = pfw


################################################################################
# Style Management
################################################################################

# A map from style name (a tuple) to the style object with that name.
styles = { }

cpdef get_style(name):
    """
    Gets the style with `name`, which must be a string.

    If the style doesn't exist, and it contains an underscore in it, creates
    a new style that has as a parent the part after the first underscore, if
    a parent with that name exists.
    """

    nametuple = (name,)

    rv = styles.get(nametuple, None)
    if rv is not None:
        return rv

    start, _mid, end = name.partition("_")

    # We need both sides of the _, as we don't want to have
    # _foo auto-inherit from foo.
    if not start or not end:
        raise Exception("Style %r does not exist." % name)

    try:
        parent = get_style(end)
    except:
        raise Exception("Style %r does not exist." % name)

    rv = Style(parent, name=nametuple)
    styles[nametuple] = rv
    return rv


cpdef get_full_style(name):
    """
    Gets the style with `name`, which must be a tuple.
    """

    rv = styles.get(name, None)
    if rv is not None:
        return rv

    rv = get_style(name[0])

    for i in name[1:]:
        rv = rv[i]

    return rv


cpdef get_tuple_name(s):
    """
    Gets the tuple name of a style, where `s` may be a tuple, Style, or string.

    If `s` is None, returns None.
    """

    if isinstance(s, StyleCore):
        return s.name
    elif isinstance(s, tuple):
        return s
    elif s is None:
        return s
    else:
        return (s,)


def get_text_style(style, default):
    """
    If `style` + "_text", exists, returns it. Otherwise, returns the default
    style, which must be given as a Style.

    For indexed styles, this is applied first, and then indexing is applied.
    """

    style = get_tuple_name(style)

    if style is None:
        return None

    start = style[:1]
    rest = style[1:]

    rv = styles.get(style, None)
    if rv is None:
        rv = get_style(default)
    else:
        rv = default

    for i in rest:
        rv = rv[i]

    return rv


class StyleManager(object):
    """
    The object exported as style in the store.
    """

    def __setattr__(self, name, value):

        if not isinstance(value, StyleCore):
            raise Exception("Value is not a style.")

        name = (name,)

        if value.name is None:
            value.name = name

        styles[name] = value

    __setitem__ = __setattr__

    def __getattr__(self, name):
        return get_style(name)

    __getitem__ = __getattr__

    def create(self, name, parent, description=None):
        """
        Deprecated way of creating styles.
        """

        s = Style(parent, help=description)
        self[name] = s

    def rebuild(self):
        renpy.style.rebuild()

    def exists(self, name):
        """
        Returns `true` if name is a style.
        """

        return (name in styles) or ((name,) in styles)

    def get(self, name):
        """
        Gets a style, which may be a name or a tuple.
        """

        if isinstance(name, tuple):
            return get_full_style(name)
        else:
            return get_style(name)


################################################################################
# Style Class
################################################################################

cdef class StyleCore:

    def __init__(self, parent, properties=None, name=None, help=None, heavy=True):
        """
        `parent`
            The parent of this style. One of:

            * A Style object.
            * A string giving the name of a style.
            * A tuple giving the name of an indexed style.
            * None, to indicate there is no parent.

        `properties`
            A map from style property to its value.

        `name`
            If given, a tuple that will be the name of this style.

        `help`
            Help information for this style.

        `heavy`
            Ignored, but retained for compatibility.
        """

        self.prefix = "insensitive_"
        self.offset = INSENSITIVE_PREFIX

        self.properties = [ ]

        if properties:
            self.properties.append(properties)

        self.parent = get_tuple_name(parent)
        self.name = name
        self.help = help

    def __dealloc__(self):
        cdef int i

        if self.cache != NULL:

            for 0 <= i < PREFIX_COUNT * STYLE_PROPERTY_COUNT:
                Py_XDECREF(self.cache[i])

            free(self.cache)

    def __getstate__(self):

        rv = dict(
            properties=self.properties,
            prefix=self.prefix,
            name=self.name,
            parent=self.parent)

        return rv

    def __setstate__(self, state):

        self.properties = state["properties"]
        self.name = state["name"]
        self.set_parent(state["parent"])
        self.set_prefix(state["prefix"])

    def __repr__(self):
        return "<{} parent={}>".format(self.name, self.parent)

    def __getitem__(self, name):
        tname = self.name + (name,)

        rv = styles.get(tname, None)
        if rv is not None:
            return rv

        if self.parent is not None:
            parent = self.parent + (name,)
        else:
            parent = None

        rv = Style(parent, name=tname)
        styles[tname] = rv
        return rv

    def setattr(self, property, value): # @ReservedAssignment
        self.properties.append({ property : value })

    def delattr(self, property): # @ReservedAssignment
        for d in self.properties:
            if property in d:
                del d[property]

    def set_parent(self, parent):
        self.parent = get_tuple_name(parent)

    def clear(self):
        self.properties = [ ]

    def take(self, other):
        self.properties = other.properties[:]

    def setdefault(self, **properties):
        """
        This sets the default value of the given properties, if no more
        explicit values have been set.
        """

        for p in self.properties:
            for k in p:
                if k in properties:
                    del properties[k]

        if properties:
            self.properties.append(properties)


    def set_prefix(self, prefix):
        """
        Sets the style_prefix to `prefix`.
        """

        if prefix == self.prefix:
            return

        self.prefix = prefix

        if prefix == "insensitive_":
            self.offset = INSENSITIVE_PREFIX
        elif prefix == "idle_":
            self.offset = IDLE_PREFIX
        elif prefix == "hover_":
            self.offset = HOVER_PREFIX
        elif prefix == "selected_insensitive_":
            self.offset = SELECTED_INSENSITIVE_PREFIX
        elif prefix == "selected_idle_":
            self.offset = SELECTED_IDLE_PREFIX
        elif prefix == "selected_hover_":
            self.offset = SELECTED_HOVER_PREFIX

    def get_placement(self):
        """
        Returns a tuple giving the placement of the object.
        """
        return (
            self._get(XPOS_INDEX),
            self._get(YPOS_INDEX),
            self._get(XANCHOR_INDEX),
            self._get(YANCHOR_INDEX),
            self._get(XOFFSET_INDEX),
            self._get(YOFFSET_INDEX),
            self._get(SUBPIXEL_INDEX),
            )

    cpdef _get(StyleCore self, int index):
        """
        Retrieves the property at `index` from this style or its parents.
        """

        cdef PyObject *o

        # The current style object we're looking at.
        cdef StyleCore s

        # The style object we'll backtrack to when s has no down-parent.
        cdef StyleCore left

        index += self.offset

        if not self.built:
            build_style(self)

        s = self
        left = None

        while True:

            # If we have the style, return it.
            if s.cache != NULL:
                o = s.cache[index]
                if o != NULL:
                    return <object> o

            # If there is no left-parent, and we have one, store it.
            if left is None and s.left_parent is not None:
                left = s.left_parent

            s = s.down_parent

            # If no down-parent, try left.
            if s is None:
                s = left
                left = None

            # If no down-parent or left-parent, default to None.
            if s is None:
                return None

from renpy.styleclass import Style

cpdef build_style(StyleCore s):

    if s.built:
        return

    s.built = True

    # Find our parents.
    if s.parent is not None:
        s.down_parent = get_full_style(s.parent)
        build_style(s.down_parent)

    if s.name is not None and len(s.name) > 1:
        s.left_parent = get_full_style(s.name[:-1])
        build_style(s.left_parent)

    # Build the properties cache.
    if not s.properties:
        s.cache = NULL
        return

    cdef int cache_priorities[PREFIX_COUNT * STYLE_PROPERTY_COUNT]
    cdef dict d
    cdef PropertyFunctionWrapper pfw

    memset(cache_priorities, 0, sizeof(int) * PREFIX_COUNT * STYLE_PROPERTY_COUNT)

    s.cache = <PyObject **> calloc(PREFIX_COUNT * STYLE_PROPERTY_COUNT, sizeof(PyObject *))

    priority = 1

    for d in s.properties:
        for k, v in d.items():
            pfw = property_functions.get(k, None)

            if pfw is None:
                continue

            pfw.function(s.cache, cache_priorities, priority, v)

        priority += PRIORITY_LEVELS


cpdef unbuild_style(StyleCore s):

    if not s.built:
        return

    if s.cache != NULL:
        free(s.cache)
        s.cache = NULL

    s.left_parent = None
    s.down_parent = None

    s.built = False


################################################################################
# Other functions
################################################################################

def reset():
    """
    Reset the style system.
    """

    styles.clear()

def build_styles():
    """
    Builds or rebuilds all styles.
    """

    for s in styles.values():
        unbuild_style(s)

    for s in styles.values():
        build_style(s)

def rebuild():
    """
    Rebuilds all styles.
    """

    build_styles()

def copy_properties(p):
    """
    Makes a copy of the properties dict p.
    """

    return [ dict(i) for i in p ]

def backup():
    """
    Returns an opaque object that backs up the current styles.
    """

    rv = { }

    for k, v in styles.iteritems():
        rv[k] = (v.parent, copy_properties(v.properties))

    return rv

def restore(o):
    """
    Restores a style backup.
    """

    for k, v in o.iteritems():
        s = get_full_style(k)

        parent, properties = v

        s.set_parent(parent)
        s.properties = copy_properties(properties)

# TODO: write_text
# TODO: style_heirarchy
