/**
 * JS functions meant for use in the Edit page.
 * Mostly dealing with plugins.
 */
const Edit = {};

Edit.tagInput = {};
Edit.suggestions = [];

Edit.hideTags = function () {
    $("#tag-spinner").css("display", "block");
    $("#tagText").css("opacity", "0.5");
    $("#tagText").prop("disabled", true);
    $("#plugin-table").hide();
};

Edit.showTags = function () {
    $("#tag-spinner").css("display", "none");
    $("#tagText").prop("disabled", false);
    $("#tagText").css("opacity", "1");
    $("#plugin-table").show();
};

Edit.focusTagInput = function () {
    // Focus child of tagger-new
    $(".tagger-new").children()[0].focus();
};

Edit.initializeAll = function () {
    // bind events to DOM
    $(document).on("click.show-help", "#show-help", Edit.showHelp);
    $(document).on("click.run-plugin", "#run-plugin", Edit.runPlugin);
    $(document).on("click.save-metadata", "#save-metadata", Edit.saveMetadata);
    $(document).on("click.delete-archive", "#delete-archive", Edit.deleteArchive);
    $(document).on("change.plugin", "#plugin", Edit.updateOneShotArg);
    $(document).on("click.tagger", ".tagger", Edit.focusTagInput);

    Edit.updateOneShotArg();

    // Hide tag input while statistics load
    Edit.hideTags();

    Server.callAPI("/api/database/stats?minweight=2", "GET", null, "�޷����ر�ǩͳ����Ϣ",
        (data) => {
            Edit.suggestions = data.reduce((res, tag) => {
                let label = tag.text;
                if (tag.namespace !== "") { label = `${tag.namespace}:${tag.text}`; }
                res.push(label);
                return res;
            }, []);
        })
        .finally(() => {
            const input = $("#tagText")[0];

            Edit.showTags();

            // Initialize tagger unless we're on a mobile OS (#531)
            if (!LRR.isMobile()) {
                Edit.tagInput = tagger(input, {
                    allow_duplicates: false,
                    allow_spaces: true,
                    wrap: true,
                    completion: {
                        list: Edit.suggestions,
                    },
                    link: (name) => `/?q=${name}`,
                });
            }
        });
};

Edit.showHelp = function () {
    $.toast({
        heading: "About Plugins",
        text: "������ʹ�ò���Զ���ȡ�˴浵��Ԫ���ݡ� <br/> ֻ��������˵���ѡ��һ�������Ȼ���� Go��<br/> ĳЩ������ܻ��ṩһ����ѡ��������ָ���� ��������������һ���ı��򽫿�������������������",
        hideAfter: false,
        position: "top-left",
        icon: "info",
    });
};

Edit.updateOneShotArg = function () {
    // show input
    $("#arg_label").show();
    $("#arg").show();

    const arg = `${$("#plugin").find(":selected").get(0).getAttribute("arg")} : `;

    // hide input for plugins without a oneshot argument field
    if (arg === " : ") {
        $("#arg_label").hide();
        $("#arg").hide();
    }

    $("#arg_label").html(arg);
};

Edit.saveMetadata = function () {
    Edit.hideTags();
    const id = $("#archiveID").val();

    const formData = new FormData();
    formData.append("tags", $("#tagText").val());
    formData.append("title", $("#title").val());

    return fetch(`api/archives/${id}/metadata`, { method: "PUT", body: formData })
        .then((response) => (response.ok ? response.json() : { success: 0, error: "��Ӧ����ȷ" }))
        .then((data) => {
            if (data.success) {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "Ԫ�����ѱ��棡",
                    icon: "success",
                });
            } else {
                throw new Error(data.message);
            }
        })
        .catch((error) => LRR.showErrorToast("����浵����ʱ���� :", error))
        .finally(() => {
            Edit.showTags();
        });
};

Edit.deleteArchive = function () {
    if (confirm("��ȷ��Ҫɾ���õ�����?")) {
        Server.deleteArchive($("#archiveID").val(), () => { document.location.href = "./"; });
    }
};

Edit.getTags = function () {
    Edit.hideTags();

    const pluginID = $("select#plugin option:checked").val();
    const archivID = $("#archiveID").val();
    const pluginArg = $("#arg").val();
    Server.callAPI(`../api/plugins/use?plugin=${pluginID}&id=${archivID}&arg=${pluginArg}`, "POST", null,
        "Error while fetching tags :", (result) => {
            if (result.data.title && result.data.title !== "") {
                $("#title").val(result.data.title);
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "�浵�������Ϊ :",
                    text: result.data.title,
                    icon: "info",
                });
            }

            if (result.data.new_tags !== "") {
                result.data.new_tags.split(/,\s?/).forEach((tag) => {
                    Edit.tagInput.add_tag(tag);
                });

                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "��������±�ǩ :",
                    text: result.data.new_tags,
                    icon: "info",
                });
            } else {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "û������±�ǩ��",
                    text: result.data.new_tags,
                    icon: "info",
                });
            }
        }).finally(() => {
        Edit.showTags();
    });
};

Edit.runPlugin = function () {
    Edit.saveMetadata().then(() => Edit.getTags());
};

$(document).ready(() => {
    Edit.initializeAll();
});

window.Edit = Edit;
