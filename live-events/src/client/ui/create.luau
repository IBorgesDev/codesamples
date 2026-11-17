--!strict

export type Props = { [string]: any }

local function create(class: string, props: Props, children: { Instance }?): any
    local instance = Instance.new(class :: any)
    for key, value in props do
        if key ~= "Parent" then
            (instance :: any)[key] = value
        end
    end

    if children then
        for _, child in children do
            child.Parent = instance
        end
    end

    if props.Parent then
        instance.Parent = props.Parent
    end

    return instance
end

return create
